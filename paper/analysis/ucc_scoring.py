"""Stability score S — fonte unica da formula CFIXED.

Portado de hefesto@dd2011e:compute_stability_scores.py, que implementa a
equacao da metodologia do paper (secao IV):

    s_cost = max(0, 1 - (v_cost - C_fixed) / (0.1 - C_fixed))
    s_i    = max(0, 1 - v_i / b_i)          (demais metricas)
    S      = sum(w_i * s_i)

O paper ja teve um bug (M1) causado por DUAS implementacoes divergentes desta
formula. Este modulo existe para que exista so uma: qualquer consumidor
(ucc_stats, discipline_stats, figuras) deve importar daqui.
"""

# Custo fixo do cluster privado sempre ligado (10 nos x t4g.2xlarge,
# $0.2688/hr por no, intervalos de 30s): (0.2688 * 10 * 30) / 3600
FIXED_COST = 0.0224

WEIGHTS = {
    "pending_pods":         (0.35, 100.0),
    "time_with_pending":    (0.25, 1.0),
    "cost":                 (0.25, 0.1 - FIXED_COST),  # = 0.0776
    "number_of_migrations": (0.15, 200.0),
}

METRICS = tuple(WEIGHTS)


def stability_score(metrics: dict) -> float:
    """S de uma run. `metrics`: {nome_metrica: valor medio}."""
    missing = set(WEIGHTS) - set(metrics)
    if missing:
        raise KeyError(f"metricas faltando: {sorted(missing)}")
    S = 0.0
    for name, (w, b) in WEIGHTS.items():
        v = metrics[name]
        if name == "cost":
            v = max(0.0, v - FIXED_COST)
        S += w * max(0.0, 1.0 - v / b)
    return S
