"""
Efficiency Router: online MAB routing optimizing latency-throughput tradeoff.

Each model in the pool is one bandit arm. On each request the bandit picks
a model; after the response (or failure) returns, the reward is computed and
fed back to the bandit.

Two reward functions are available (selected via config.reward_function):

  "inverse_latency":
      raw_reward = 1.0 / latency
      bandit_reward = min(raw_reward / reward_max, 1.0)

  "composite" (default):
      latency_score   = exp(-latency / target_latency)
      throughput_score = min(completion_tokens / latency / throughput_max, 1.0)
      reward = gamma * latency_score + (1 - gamma) * throughput_score

      gamma controls the tradeoff:
          gamma=1.0 -> pure latency (fast responses)
          gamma=0.0 -> pure throughput (tokens per second)

On failure: reward = 0.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from router_strategy.efficiency_router.bandit import (
    MABAlgorithm,
    make_bandit,
)


@dataclass
class EfficiencyRouterConfig:
    available_models: List[str]
    bandit: str = "ucb"
    delta: float = 0.1
    epsilon: float = 0.1
    reward_function: str = "composite"
    # inverse_latency params
    reward_max: float = 20.0
    # composite params
    gamma: float = 0.5
    target_latency: float = 1.0
    throughput_max: float = 100.0


def _reward_inverse_latency(latency_seconds: float, reward_max: float, **_: Any) -> float:
    raw = 1.0 / max(latency_seconds, 1e-6)
    return min(raw / reward_max, 1.0)


def _reward_composite(
    latency_seconds: float,
    completion_tokens: int,
    gamma: float,
    target_latency: float,
    throughput_max: float,
    **_: Any,
) -> float:
    latency_score = math.exp(-latency_seconds / target_latency)
    throughput = completion_tokens / max(latency_seconds, 1e-6)
    throughput_score = min(throughput / throughput_max, 1.0)
    return gamma * latency_score + (1.0 - gamma) * throughput_score


class EfficiencyRouter:
    """One instance per router deployment. Holds the bandit and processes rewards."""

    def __init__(self, config: EfficiencyRouterConfig) -> None:
        self.config = config
        self._bandit: MABAlgorithm = make_bandit(
            config.bandit,
            config.available_models,
            delta=config.delta,
            epsilon=config.epsilon,
        )
        self._overflow_count = 0

    def pick_model(self) -> str:
        return self._bandit.select_arm()

    def record_success(
        self, model: str, latency_seconds: float, completion_tokens: int = 0
    ) -> float:
        """Record a successful response. Returns the reward fed to the bandit."""
        if self.config.reward_function == "inverse_latency":
            reward = _reward_inverse_latency(latency_seconds, self.config.reward_max)
            raw = 1.0 / max(latency_seconds, 1e-6)
            if raw > self.config.reward_max:
                self._overflow_count += 1
        else:
            reward = _reward_composite(
                latency_seconds,
                completion_tokens,
                self.config.gamma,
                self.config.target_latency,
                self.config.throughput_max,
            )
        self._bandit.update(model, reward)
        return reward

    def record_failure(self, model: str) -> None:
        """Record a failed/timed-out request. Reward = 0."""
        self._bandit.update(model, 0.0)

    def state(self) -> Dict[str, Any]:
        return {
            "config": {
                "bandit": self.config.bandit,
                "available_models": self.config.available_models,
                "reward_function": self.config.reward_function,
                "gamma": self.config.gamma,
                "target_latency": self.config.target_latency,
                "throughput_max": self.config.throughput_max,
                "reward_max": self.config.reward_max,
            },
            "bandit_state": self._bandit.state(),
            "overflow_count": self._overflow_count,
        }


class RequestTracker:
    """Tracks in-flight requests so the post-call hook can compute latency."""

    def __init__(self) -> None:
        self._starts: Dict[str, float] = {}

    def start(self, request_id: str) -> None:
        self._starts[request_id] = time.perf_counter()

    def finish(self, request_id: str) -> Optional[float]:
        """Returns latency in seconds, or None if the request_id was not tracked."""
        t0 = self._starts.pop(request_id, None)
        if t0 is None:
            return None
        return time.perf_counter() - t0

    def cancel(self, request_id: str) -> None:
        self._starts.pop(request_id, None)
