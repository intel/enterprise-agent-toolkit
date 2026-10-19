"""
Multi-armed bandit algorithms for the efficiency router.

Reward is success/latency normalized to [0, 1]:
    raw_reward = 1.0 / latency_seconds   (on success; 0 on failure)
    bandit_reward = min(raw_reward / reward_max, 1.0)

Algorithms are pluggable. UCB and EpsilonGreedy ship; subclass MABAlgorithm
and register in BANDIT_REGISTRY to add new ones.
"""

from __future__ import annotations

import math
import random
import threading
from abc import ABC, abstractmethod
from typing import Any, Callable, Dict, List


class MABAlgorithm(ABC):
    """Thread-safe bandit base class."""

    def __init__(self, arms: List[str]):
        if len(arms) < 2:
            raise ValueError("Need at least 2 arms")
        self.arms = list(arms)
        self.n_arms = len(arms)
        self._arm_index = {name: i for i, name in enumerate(arms)}
        self.counts = [0] * self.n_arms
        self.sum_rewards = [0.0] * self.n_arms
        self.t = 0
        self._lock = threading.Lock()

    @abstractmethod
    def _select_arm_locked(self) -> int:
        ...

    def select_arm(self) -> str:
        with self._lock:
            idx = self._select_arm_locked()
            return self.arms[idx]

    def select_arm_from(self, eligible: List[str]) -> str:
        """Select an arm considering only the eligible subset."""
        with self._lock:
            return self._select_arm_from_locked(eligible)

    def _select_arm_from_locked(self, eligible: List[str]) -> str:
        """Default: pick the eligible arm with the highest score, or first unpulled."""
        best_arm = eligible[0]
        best_score = -math.inf
        for arm in eligible:
            idx = self._arm_index[arm]
            if self.counts[idx] == 0:
                return arm
            score = self.sum_rewards[idx] / self.counts[idx]
            if score > best_score:
                best_score = score
                best_arm = arm
        return best_arm

    def update(self, arm: str, reward: float) -> None:
        idx = self._arm_index[arm]
        with self._lock:
            self.counts[idx] += 1
            self.sum_rewards[idx] += reward
            self.t += 1

    def mean(self, arm: str) -> float:
        idx = self._arm_index[arm]
        return self.sum_rewards[idx] / self.counts[idx] if self.counts[idx] > 0 else 0.0

    def score_arm(self, arm: str) -> float | None:
        """Return the UCB-style score for an arm, or None if the arm hasn't been pulled."""
        idx = self._arm_index[arm]
        with self._lock:
            if self.counts[idx] == 0:
                return None
            return self.sum_rewards[idx] / self.counts[idx]

    def state(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "algorithm": type(self).__name__,
                "arms": list(self.arms),
                "t": self.t,
                "counts": {self.arms[i]: self.counts[i] for i in range(self.n_arms)},
                "means": {self.arms[i]: self.mean(self.arms[i]) for i in range(self.n_arms)},
            }


class UCB(MABAlgorithm):
    """Upper Confidence Bound (Hoeffding-style).

    B_i = sqrt(2 * ln(1/delta) / n_i)
    Select argmax(mu_i + B_i).

    Smaller delta = wider interval = more exploration.
    Each arm is pulled once before UCB takes over.
    """

    def __init__(self, arms: List[str], delta: float = 0.1):
        super().__init__(arms)
        if not (0.0 < delta < 1.0):
            raise ValueError("delta must be in (0, 1)")
        self.delta = delta

    def _select_arm_locked(self) -> int:
        for i in range(self.n_arms):
            if self.counts[i] == 0:
                return i
        log_inv_delta = math.log(1.0 / self.delta)
        best_idx = 0
        best_score = -math.inf
        for i in range(self.n_arms):
            mu = self.sum_rewards[i] / self.counts[i]
            radius = math.sqrt(2.0 * log_inv_delta / self.counts[i])
            score = mu + radius
            if score > best_score:
                best_score = score
                best_idx = i
        return best_idx

    def score_arm(self, arm: str) -> float | None:
        idx = self._arm_index[arm]
        with self._lock:
            if self.counts[idx] == 0:
                return None
            mu = self.sum_rewards[idx] / self.counts[idx]
            radius = math.sqrt(2.0 * math.log(1.0 / self.delta) / self.counts[idx])
            return mu + radius


class EpsilonGreedy(MABAlgorithm):
    """Epsilon-greedy: explore uniformly with probability epsilon, else greedy."""

    def __init__(self, arms: List[str], epsilon: float = 0.1):
        super().__init__(arms)
        if not (0.0 <= epsilon <= 1.0):
            raise ValueError("epsilon must be in [0, 1]")
        self.epsilon = epsilon

    def _select_arm_locked(self) -> int:
        for i in range(self.n_arms):
            if self.counts[i] == 0:
                return i
        if random.random() < self.epsilon:
            return random.randrange(self.n_arms)
        best_idx = 0
        best_mu = -math.inf
        for i in range(self.n_arms):
            mu = self.sum_rewards[i] / self.counts[i]
            if mu > best_mu:
                best_mu = mu
                best_idx = i
        return best_idx


class ThompsonSampling(MABAlgorithm):
    """Beta-Bernoulli Thompson Sampling.

    Maintains Beta(alpha, beta) posteriors per arm. On each selection, draws
    a sample from each arm's posterior and picks the arm with the highest sample.

    Rewards in [0, 1] are treated as fractional: alpha += reward, beta += (1 - reward).
    This generalizes the binary case (reward=0 or 1) to continuous composite rewards.
    """

    def __init__(self, arms: List[str], prior_alpha: float = 1.0, prior_beta: float = 1.0, arm_priors: Dict[str, tuple] | None = None):
        super().__init__(arms)
        if arm_priors:
            self.alpha = [arm_priors.get(arm, (prior_alpha, prior_beta))[0] for arm in arms]
            self.beta = [arm_priors.get(arm, (prior_alpha, prior_beta))[1] for arm in arms]
        else:
            self.alpha = [prior_alpha] * self.n_arms
            self.beta = [prior_beta] * self.n_arms

    def _select_arm_locked(self) -> int:
        best_idx = 0
        best_sample = -1.0
        for i in range(self.n_arms):
            sample = random.betavariate(self.alpha[i], self.beta[i])
            if sample > best_sample:
                best_sample = sample
                best_idx = i
        return best_idx

    def _select_arm_from_locked(self, eligible: List[str]) -> str:
        best_arm = eligible[0]
        best_sample = -1.0
        for arm in eligible:
            idx = self._arm_index[arm]
            sample = random.betavariate(self.alpha[idx], self.beta[idx])
            if sample > best_sample:
                best_sample = sample
                best_arm = arm
        return best_arm

    def update(self, arm: str, reward: float) -> None:
        idx = self._arm_index[arm]
        with self._lock:
            self.counts[idx] += 1
            self.sum_rewards[idx] += reward
            self.t += 1
            self.alpha[idx] += reward
            self.beta[idx] += (1.0 - reward)

    def score_arm(self, arm: str) -> float | None:
        idx = self._arm_index[arm]
        with self._lock:
            if self.counts[idx] == 0:
                return None
            return self.alpha[idx] / (self.alpha[idx] + self.beta[idx])

    def state(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "algorithm": type(self).__name__,
                "arms": list(self.arms),
                "t": self.t,
                "counts": {self.arms[i]: self.counts[i] for i in range(self.n_arms)},
                "means": {self.arms[i]: self.mean(self.arms[i]) for i in range(self.n_arms)},
                "alpha": {self.arms[i]: self.alpha[i] for i in range(self.n_arms)},
                "beta": {self.arms[i]: self.beta[i] for i in range(self.n_arms)},
            }


BANDIT_REGISTRY: Dict[str, Callable[..., MABAlgorithm]] = {
    "ucb": lambda arms, delta=0.1, **_: UCB(arms, delta=delta),
    "epsilon_greedy": lambda arms, epsilon=0.1, **_: EpsilonGreedy(arms, epsilon=epsilon),
    "thompson": lambda arms, prior_alpha=1.0, prior_beta=1.0, arm_priors=None, **_: ThompsonSampling(arms, prior_alpha=prior_alpha, prior_beta=prior_beta, arm_priors=arm_priors),
}


def make_bandit(name: str, arms: List[str], **kwargs: Any) -> MABAlgorithm:
    if name not in BANDIT_REGISTRY:
        raise ValueError(f"Unknown bandit '{name}'. Available: {sorted(BANDIT_REGISTRY)}")
    return BANDIT_REGISTRY[name](arms, **kwargs)