"""
Hybrid Router: two-layer routing combining quality gating with online efficiency.

Layer 1 (Complexity): classifies the request and produces a set of eligible models.
Layer 2 (Efficiency): picks the best model from that set using a per-tier MAB bandit
that optimizes for latency and throughput in real time.

The per-tier bandit design means each tier tracks arm performance independently.
A model might be fast for SIMPLE queries but slow for COMPLEX ones (longer generation),
and the bandits learn this separately.
"""

from __future__ import annotations

import re
import threading
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Set, Tuple

from litellm.router_strategy.complexity_router.config import (
    ComplexityRouterConfig,
    ComplexityTier,
    DEFAULT_CODE_KEYWORDS,
    DEFAULT_REASONING_KEYWORDS,
    DEFAULT_SIMPLE_KEYWORDS,
    DEFAULT_TECHNICAL_KEYWORDS,
)
from router_strategy.efficiency_router.bandit import MABAlgorithm, make_bandit


@dataclass
class HybridRouterConfig:
    tier_candidates: Dict[str, List[str]]
    bandit: str = "ucb"
    delta: float = 0.1
    epsilon: float = 0.1
    target_tpt: float = 1.0
    complexity_router_config: Optional[Dict[str, Any]] = None
    tier_priors: Optional[Dict[str, Dict[str, Tuple[float, float]]]] = None


class TierBandit:
    """A bandit instance scoped to one complexity tier."""

    def __init__(self, tier: str, arms: List[str], bandit_type: str, arm_priors: Optional[Dict[str, Tuple[float, float]]] = None, **bandit_kwargs):
        self.tier = tier
        self.arms = list(arms)
        self._bandit: MABAlgorithm = make_bandit(bandit_type, arms, arm_priors=arm_priors, **bandit_kwargs)

    def pick(self) -> str:
        return self._bandit.select_arm()

    def pick_from(self, eligible: List[str]) -> str:
        """Pick an arm from eligible using the bandit's stochastic selection."""
        if len(eligible) == 1:
            return eligible[0]
        return self._bandit.select_arm_from(eligible)

    def update(self, arm: str, reward: float) -> None:
        self._bandit.update(arm, reward)

    def state(self) -> Dict[str, Any]:
        return {
            "tier": self.tier,
            **self._bandit.state(),
        }


class HybridRouter:
    """
    Two-layer router: complexity classification -> per-tier MAB selection.

    Usage:
        config = HybridRouterConfig(
            tier_candidates={
                "SIMPLE": ["model-small", "model-medium"],
                "MEDIUM": ["model-medium", "model-large"],
                "COMPLEX": ["model-large", "model-xl"],
                "REASONING": ["model-xl"],
            },
            ...
        )
        router = HybridRouter(config)

        # On each request:
        tier, model = router.route(user_message, system_prompt)

        # After response:
        router.record_success(tier, model, latency, completion_tokens)
    """

    def __init__(self, config: HybridRouterConfig) -> None:
        self.config = config
        self._tier_candidates: Dict[str, List[str]] = config.tier_candidates

        all_models: Set[str] = set()
        for models in self._tier_candidates.values():
            all_models.update(models)
        self._all_models = sorted(all_models)

        bandit_kwargs = {"delta": config.delta, "epsilon": config.epsilon}
        self._tier_bandits: Dict[str, TierBandit] = {}
        for tier_name, candidates in self._tier_candidates.items():
            if len(candidates) >= 2:
                arm_priors = (config.tier_priors or {}).get(tier_name)
                self._tier_bandits[tier_name] = TierBandit(
                    tier=tier_name,
                    arms=candidates,
                    bandit_type=config.bandit,
                    arm_priors=arm_priors,
                    **bandit_kwargs,
                )

        self._classifier_config = ComplexityRouterConfig(
            **(config.complexity_router_config or {})
        )
        self._code_keywords = self._classifier_config.code_keywords or DEFAULT_CODE_KEYWORDS
        self._reasoning_keywords = self._classifier_config.reasoning_keywords or DEFAULT_REASONING_KEYWORDS
        self._technical_keywords = self._classifier_config.technical_keywords or DEFAULT_TECHNICAL_KEYWORDS
        self._simple_keywords = self._classifier_config.simple_keywords or DEFAULT_SIMPLE_KEYWORDS
        self._multi_step_patterns = [
            re.compile(r"first.*?then", re.IGNORECASE),
            re.compile(r"step\s*\d", re.IGNORECASE),
            re.compile(r"\d+\.\s"),
            re.compile(r"[a-z]\)\s", re.IGNORECASE),
        ]

        self._lock = threading.Lock()

    def classify(self, user_message: str, system_prompt: Optional[str] = None) -> Tuple[ComplexityTier, float, List[str]]:
        full_text = f"{system_prompt or ''} {user_message}".lower()
        user_text = user_message.lower()
        estimated_tokens = len(user_message) // 4

        token_thresholds = self._classifier_config.token_thresholds
        simple_threshold = token_thresholds.get("simple", 15)
        complex_threshold = token_thresholds.get("complex", 400)

        scores: Dict[str, float] = {}
        signals: List[str] = []

        if estimated_tokens < simple_threshold:
            scores["tokenCount"] = -1.0
        elif estimated_tokens > complex_threshold:
            scores["tokenCount"] = 1.0
        else:
            scores["tokenCount"] = 0.0

        def keyword_score(text: str, keywords: List[str], name: str, label: str, thresholds: Tuple[int, int], score_vals: Tuple[float, float, float]) -> int:
            matches = []
            for kw in keywords:
                kw_lower = kw.lower()
                if " " not in kw_lower:
                    if re.search(r"\b" + re.escape(kw_lower) + r"\b", text):
                        matches.append(kw)
                elif kw_lower in text:
                    matches.append(kw)
            count = len(matches)
            low_t, high_t = thresholds
            if count >= high_t:
                scores[name] = score_vals[2]
                signals.append(f"{label} ({', '.join(matches[:3])})")
            elif count >= low_t:
                scores[name] = score_vals[1]
                signals.append(f"{label} ({', '.join(matches[:3])})")
            else:
                scores[name] = score_vals[0]
            return count

        keyword_score(full_text, self._code_keywords, "codePresence", "code", (1, 2), (0, 0.5, 1.0))
        reasoning_count = keyword_score(user_text, self._reasoning_keywords, "reasoningMarkers", "reasoning", (1, 2), (0, 0.7, 1.0))
        keyword_score(full_text, self._technical_keywords, "technicalTerms", "technical", (2, 4), (0, 0.5, 1.0))
        keyword_score(full_text, self._simple_keywords, "simpleIndicators", "simple", (1, 2), (0, -1.0, -1.0))

        multi_step_hits = sum(1 for p in self._multi_step_patterns if p.search(full_text))
        scores["multiStepPatterns"] = 0.5 if multi_step_hits > 0 else 0.0

        q_count = user_message.count("?")
        scores["questionComplexity"] = 0.5 if q_count > 3 else 0.0

        weights = self._classifier_config.dimension_weights
        weighted_score = sum(scores.get(name, 0) * w for name, w in weights.items())

        if reasoning_count >= 2:
            return ComplexityTier.REASONING, weighted_score, signals

        boundaries = self._classifier_config.tier_boundaries
        simple_medium = boundaries.get("simple_medium", 0.15)
        medium_complex = boundaries.get("medium_complex", 0.35)
        complex_reasoning = boundaries.get("complex_reasoning", 0.60)

        if weighted_score < simple_medium:
            tier = ComplexityTier.SIMPLE
        elif weighted_score < medium_complex:
            tier = ComplexityTier.MEDIUM
        elif weighted_score < complex_reasoning:
            tier = ComplexityTier.COMPLEX
        else:
            tier = ComplexityTier.REASONING

        return tier, weighted_score, signals

    def get_candidates(self, tier: ComplexityTier) -> List[str]:
        tier_key = tier.value if isinstance(tier, ComplexityTier) else tier
        candidates = self._tier_candidates.get(tier_key)
        if not candidates:
            for t in ["MEDIUM", "COMPLEX", "SIMPLE", "REASONING"]:
                if t in self._tier_candidates:
                    return self._tier_candidates[t]
            return self._all_models
        return candidates

    def pick_model(self, tier: ComplexityTier) -> str:
        tier_key = tier.value if isinstance(tier, ComplexityTier) else tier
        candidates = self.get_candidates(tier)

        if len(candidates) == 1:
            return candidates[0]

        bandit = self._tier_bandits.get(tier_key)
        if bandit is None:
            return candidates[0]

        return bandit.pick_from(candidates)

    def route(self, user_message: str, system_prompt: Optional[str] = None) -> Tuple[ComplexityTier, str]:
        tier, score, signals = self.classify(user_message, system_prompt)
        model = self.pick_model(tier)
        return tier, model

    def _compute_reward(self, latency_seconds: float, completion_tokens: int) -> float:
        time_per_token = latency_seconds / max(completion_tokens, 1)
        return self.config.target_tpt / (self.config.target_tpt + time_per_token)

    def record_success(
        self, tier: ComplexityTier, model: str, latency_seconds: float, completion_tokens: int = 0
    ) -> float:
        tier_key = tier.value if isinstance(tier, ComplexityTier) else tier
        reward = self._compute_reward(latency_seconds, completion_tokens)
        bandit = self._tier_bandits.get(tier_key)
        if bandit is not None:
            bandit.update(model, reward)
        return reward

    def record_quality(
        self,
        tier: ComplexityTier,
        model: str,
        latency_seconds: float,
        completion_tokens: int,
        quality_score: float,
        quality_weight: float = 0.5,
    ) -> float:
        """Record a composite reward blending efficiency and quality.

        Args:
            quality_score: Judge/quality score in [0, 1].
            quality_weight: How much to weight quality vs efficiency. 0.5 = equal.

        Returns:
            The composite reward that was fed to the bandit.
        """
        tier_key = tier.value if isinstance(tier, ComplexityTier) else tier
        eff_reward = self._compute_reward(latency_seconds, completion_tokens)
        composite = (1.0 - quality_weight) * eff_reward + quality_weight * quality_score
        bandit = self._tier_bandits.get(tier_key)
        if bandit is not None:
            bandit.update(model, composite)
        return composite

    def record_failure(self, tier: ComplexityTier, model: str) -> None:
        tier_key = tier.value if isinstance(tier, ComplexityTier) else tier
        bandit = self._tier_bandits.get(tier_key)
        if bandit is not None:
            bandit.update(model, 0.0)

    def state(self) -> Dict[str, Any]:
        return {
            "config": {
                "bandit": self.config.bandit,
                "tier_candidates": self.config.tier_candidates,
                "target_tpt": self.config.target_tpt,
            },
            "tier_bandits": {
                tier: bandit.state()
                for tier, bandit in self._tier_bandits.items()
            },
        }