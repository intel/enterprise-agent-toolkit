"""
Custom Hybrid Router for LiteLLM Proxy.

Plugs into LiteLLM's native auto_router/ infrastructure via a monkey-patch,
matching the same pattern as the built-in ComplexityRouter.

How it works
────────────
1.  This module is imported at proxy startup via ``litellm_settings.callbacks``.
    At import time it monkey-patches ``litellm.router.Router`` to support a new
    ``auto_router/hybrid_router`` model-prefix — identical in design to how
    ``auto_router/complexity_router`` works.

2.  Configure a virtual model entry in config.yaml:
      - model_name: hybrid-router
        litellm_params:
          model: auto_router/hybrid_router
          hybrid_router_config:
            bandit: thompson
            delta: 0.1
            epsilon: 0.1
            target_tpt: 1.0
            quality_weight: 0.0
            tier_candidates:
              SIMPLE:    [llama-8b, llama-70b]
              MEDIUM:    [llama-8b, llama-70b]
              COMPLEX:   [llama-70b]
              REASONING: [llama-70b]
            complexity_router_config:
              tier_boundaries:
                simple_medium: 0.15
                medium_complex: 0.35
                complex_reasoning: 0.60
          hybrid_router_default_model: llama-8b

3.  Clients call model="hybrid-router".
    Router.async_pre_routing_hook (patched) intercepts before any deployment
    is selected, classifies the prompt, picks the best real model via the MAB
    bandit, and returns a PreRoutingHookResponse — exactly like ComplexityRouter.

4.  async_log_success/failure_event record latency rewards back to the bandit.

config.yaml snippet:
  litellm_settings:
    callbacks: custom_hybrid_router.proxy_handler_instance
  general_settings:
    master_key: os.environ/LITELLM_MASTER_KEY
    store_model_in_db: false
"""

from __future__ import annotations

import os
import sys
import time
import threading
from typing import Any, Dict, List, Optional, Union

from litellm.integrations.custom_logger import CustomLogger

_APP_DIR = os.path.dirname(os.path.abspath(__file__))
if _APP_DIR not in sys.path:
    sys.path.insert(0, _APP_DIR)

# Imported after the sys.path insert above: router_strategy/ is mounted flat
# alongside this file by the genai-gateway-router-code ConfigMap.
from router_strategy.hybrid_router.hybrid_router import (  # noqa: E402
    HybridRouter,
    HybridRouterConfig,
)


class _RequestState:
    __slots__ = ("tier", "model", "t0")

    def __init__(self, tier: Any, model: str, t0: float) -> None:
        self.tier = tier
        self.model = model
        self.t0 = t0


class HybridRouterProxy(CustomLogger):
    """
    One instance per configured hybrid-router model entry.
    Implements async_pre_routing_hook (same interface as ComplexityRouter) plus
    async_log_success/failure_event for bandit reward recording.
    """

    def __init__(
        self,
        model_name: str,
        hybrid_router_config: Optional[Dict[str, Any]],
        default_model: str,
        litellm_router_instance: Any,
    ) -> None:
        super().__init__()
        self.model_name = model_name
        self._lock = threading.Lock()
        self._in_flight: Dict[str, _RequestState] = {}

        hr_cfg = hybrid_router_config or {}
        tier_candidates: Dict[str, list] = hr_cfg.get("tier_candidates", {
            "SIMPLE":    [default_model],
            "MEDIUM":    [default_model],
            "COMPLEX":   [default_model],
            "REASONING": [default_model],
        })
        self._quality_weight = float(hr_cfg.get("quality_weight", 0.0))

        config = HybridRouterConfig(
            tier_candidates=tier_candidates,
            bandit=hr_cfg.get("bandit", "thompson"),
            delta=float(hr_cfg.get("delta", 0.1)),
            epsilon=float(hr_cfg.get("epsilon", 0.1)),
            target_tpt=float(hr_cfg.get("target_tpt", 1.0)),
            complexity_router_config=hr_cfg.get("complexity_router_config"),
            tier_priors=hr_cfg.get("tier_priors"),
        )
        self._router = HybridRouter(config)

        print(
            f"[HybridRouterProxy] Initialised model_name={model_name} "
            f"bandit={config.bandit} default={default_model} "
            f"tiers={list(tier_candidates.keys())}"
        )

    async def async_pre_routing_hook(
        self,
        model: str,
        request_kwargs: Dict,
        messages: Optional[List[Dict[str, Any]]] = None,
        input: Optional[Union[str, List]] = None,
        specific_deployment: Optional[bool] = False,
    ) -> Any:
        from litellm.types.router import PreRoutingHookResponse

        user_message = ""
        system_prompt = ""
        if messages:
            for msg in messages:
                role = msg.get("role", "")
                content = msg.get("content") or ""
                if isinstance(content, list):
                    content = " ".join(
                        part.get("text", "") for part in content
                        if isinstance(part, dict) and part.get("type") == "text"
                    )
                if isinstance(content, str) and content:
                    if role == "user":
                        user_message += content + " "
                    elif role == "system":
                        system_prompt += content + " "

        tier, chosen_model = self._router.route(
            user_message.strip(),
            system_prompt.strip() or None,
        )

        call_id = request_kwargs.get("litellm_call_id", "")
        if call_id:
            with self._lock:
                self._in_flight[call_id] = _RequestState(
                    tier=tier, model=chosen_model, t0=time.perf_counter()
                )

        tier_str = tier.value if hasattr(tier, "value") else str(tier)
        print(
            f"[HybridRouterProxy] model={self.model_name} call_id={call_id} "
            f"tier={tier_str} -> {chosen_model}"
        )
        return PreRoutingHookResponse(model=chosen_model, messages=messages)

    async def async_log_success_event(
        self,
        kwargs: Dict,
        response_obj: Any,
        start_time: Any,
        end_time: Any,
    ) -> None:
        call_id = kwargs.get("litellm_call_id", "")
        with self._lock:
            state = self._in_flight.pop(call_id, None)
        if state is None:
            return
        try:
            latency = (end_time - start_time).total_seconds()
        except Exception:
            latency = 0.0
        try:
            tokens = response_obj.usage.completion_tokens if response_obj.usage else 0
        except Exception:
            tokens = 0
        if self._quality_weight > 0:
            self._router.record_quality(
                state.tier, state.model, latency, tokens,
                quality_score=0.5, quality_weight=self._quality_weight,
            )
        else:
            self._router.record_success(state.tier, state.model, latency, tokens)

    async def async_log_failure_event(
        self,
        kwargs: Dict,
        response_obj: Any,
        start_time: Any,
        end_time: Any,
    ) -> None:
        call_id = kwargs.get("litellm_call_id", "")
        with self._lock:
            state = self._in_flight.pop(call_id, None)
        if state is None:
            return
        self._router.record_failure(state.tier, state.model)

    def router_state(self) -> Dict[str, Any]:
        return self._router.state()


def _apply_router_patch() -> None:
    """
    Monkey-patch litellm.router.Router to add auto_router/hybrid_router support.
    Idempotent — guarded by Router._HYBRID_ROUTER_PATCHED flag.
    """
    from litellm.router import Router

    if getattr(Router, "_HYBRID_ROUTER_PATCHED", False):
        return

    def _is_hybrid_router_deployment(self, litellm_params: Any) -> bool:
        return litellm_params.model.startswith("auto_router/hybrid_router")

    def _init_hybrid_router_deployment(self, deployment: Any) -> None:
        import litellm
        if not hasattr(self, "hybrid_routers"):
            self.hybrid_routers: Dict[str, HybridRouterProxy] = {}

        lp = deployment.litellm_params
        hr_cfg: Optional[Dict[str, Any]] = lp.get("hybrid_router_config") or None
        default_model: Optional[str] = lp.get("hybrid_router_default_model")

        if default_model is None and hr_cfg:
            tc = hr_cfg.get("tier_candidates", {})
            default_model = (
                (tc.get("SIMPLE") or [None])[0]
                or (tc.get("MEDIUM") or [None])[0]
            )
        if default_model is None:
            raise ValueError(
                f"hybrid_router_default_model is required for "
                f"hybrid-router deployment '{deployment.model_name}'."
            )
        proxy = HybridRouterProxy(
            model_name=deployment.model_name,
            hybrid_router_config=hr_cfg,
            default_model=default_model,
            litellm_router_instance=self,
        )
        self.hybrid_routers[deployment.model_name] = proxy
        if proxy not in litellm.callbacks:
            litellm.callbacks.append(proxy)

    Router._is_hybrid_router_deployment = _is_hybrid_router_deployment
    Router._init_hybrid_router_deployment = _init_hybrid_router_deployment

    # Patch _is_auto_router_deployment to exclude our prefix (it would otherwise
    # return True for any "auto_router/" prefix not explicitly excluded)
    _orig_is_auto = Router._is_auto_router_deployment

    def _patched_is_auto_router_deployment(self, litellm_params: Any) -> bool:
        if litellm_params.model.startswith("auto_router/hybrid_router"):
            return False  # handled by our patch
        return _orig_is_auto(self, litellm_params)

    Router._is_auto_router_deployment = _patched_is_auto_router_deployment

    # Patch _add_deployment to also init hybrid_routers when appropriate.
    # _add_deployment is where all auto_router/* checks live.
    _orig_add = Router._add_deployment

    def _patched_add_deployment(self, deployment: Any) -> Any:
        result = _orig_add(self, deployment)
        if self._is_hybrid_router_deployment(result.litellm_params):
            if not hasattr(self, "hybrid_routers"):
                self.hybrid_routers = {}
            if result.model_name not in self.hybrid_routers:
                self._init_hybrid_router_deployment(result)
        return result

    Router._add_deployment = _patched_add_deployment

    _orig_hook = Router.async_pre_routing_hook

    async def _patched_async_pre_routing_hook(
        self,
        model: str,
        request_kwargs: Dict,
        messages: Optional[List] = None,
        input: Optional[Any] = None,
        specific_deployment: Optional[bool] = False,
    ) -> Any:
        if hasattr(self, "hybrid_routers") and model in self.hybrid_routers:
            return await self.hybrid_routers[model].async_pre_routing_hook(
                model=model,
                request_kwargs=request_kwargs,
                messages=messages,
                input=input,
                specific_deployment=specific_deployment,
            )
        return await _orig_hook(
            self,
            model=model,
            request_kwargs=request_kwargs,
            messages=messages,
            input=input,
            specific_deployment=specific_deployment,
        )

    Router.async_pre_routing_hook = _patched_async_pre_routing_hook
    Router._HYBRID_ROUTER_PATCHED = True
    print("[HybridRouterProxy] litellm.router.Router patched for auto_router/hybrid_router")


_apply_router_patch()


class _ImportTriggerLogger(CustomLogger):
    """No-op logger; sole purpose is to trigger module import and Router patching."""
    pass


proxy_handler_instance = _ImportTriggerLogger()
