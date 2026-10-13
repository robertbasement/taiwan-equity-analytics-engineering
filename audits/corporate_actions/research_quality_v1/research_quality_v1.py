#!/usr/bin/env python3
"""Research Quality Layer V1: local adapter, never a production price repair."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd


QUALITY_VALUES = {"VALID", "INVALID", "UNKNOWN"}
ANOMALY_COLUMNS = {
    "ticker", "prev_quote_date", "quote_date", "raw_return",
    "adjusted_return", "missing_market_sessions", "anomaly_reason",
    "anomaly_source", "source_audit_version", "is_material_gt50",
}
OBSERVATION_KEY = ["rebalance_date", "ticker"]


def load_anomalies(path: str | Path) -> pd.DataFrame:
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"anomaly input is missing: {path}")
    anomalies = pd.read_csv(path, dtype={"ticker": str})
    missing = ANOMALY_COLUMNS - set(anomalies.columns)
    if missing:
        raise ValueError(f"malformed anomaly input; missing columns: {sorted(missing)}")
    for column in ("prev_quote_date", "quote_date"):
        anomalies[column] = pd.to_datetime(anomalies[column], errors="raise")
    if (anomalies["prev_quote_date"] >= anomalies["quote_date"]).any():
        raise ValueError("malformed anomaly input; transition dates are not increasing")
    for column in ("raw_return", "adjusted_return"):
        anomalies[column] = pd.to_numeric(anomalies[column], errors="raise")
        if not np.isfinite(anomalies[column]).all():
            raise ValueError(f"non-finite {column} in anomaly input")
    anomalies["missing_market_sessions"] = pd.to_numeric(
        anomalies["missing_market_sessions"], errors="raise"
    ).astype("Int64")
    for column in ("ticker", "anomaly_reason", "anomaly_source", "source_audit_version"):
        if anomalies[column].isna().any() or anomalies[column].astype(str).str.strip().eq("").any():
            raise ValueError(f"malformed anomaly input; empty {column}")
    flag = anomalies["is_material_gt50"]
    if not pd.api.types.is_bool_dtype(flag):
        normalized = flag.astype(str).str.strip().str.lower().map({"true": True, "false": False})
        if normalized.isna().any():
            raise ValueError("malformed anomaly input; is_material_gt50 must be boolean")
        anomalies["is_material_gt50"] = normalized.astype(bool)
    if anomalies.duplicated(["ticker", "prev_quote_date", "quote_date"]).any():
        raise ValueError("duplicate anomaly transition key")
    material = anomalies[anomalies["is_material_gt50"]]
    if not (material["adjusted_return"].abs() > 0.50).all():
        raise ValueError("material row violates abs(adjusted_return) > 0.50")
    if (anomalies["is_material_gt50"] != anomalies["adjusted_return"].abs().gt(0.50)).any():
        raise ValueError("material flag disagrees with abs(adjusted_return) > 0.50")
    return anomalies.sort_values(["ticker", "quote_date", "prev_quote_date"]).reset_index(drop=True)


def validate_research_panel(panel: pd.DataFrame) -> pd.DataFrame:
    required = {
        "rebalance_date", "next_rebalance_date", "ticker", "yoy_growth",
        "forward_return", "forward_return_eligible", "price_ma20_gap", "price_ma60_gap",
    }
    missing = required - set(panel.columns)
    if missing:
        raise ValueError(f"research panel missing columns: {sorted(missing)}")
    result = panel.copy()
    result["ticker"] = result["ticker"].astype(str)
    result["rebalance_date"] = pd.to_datetime(result["rebalance_date"], errors="raise")
    result["next_rebalance_date"] = pd.to_datetime(result["next_rebalance_date"], errors="coerce")
    if result.duplicated(OBSERVATION_KEY).any():
        raise ValueError("duplicate research observation key")
    return result


def build_relationships_python(
    panel: pd.DataFrame,
    price_rows: pd.DataFrame,
    anomalies: pd.DataFrame,
) -> pd.DataFrame:
    """Small-fixture reference implementation of exact interval/window semantics."""
    panel = validate_research_panel(panel)
    prices = price_rows.copy()
    prices["ticker"] = prices["ticker"].astype(str)
    prices["date"] = pd.to_datetime(prices["date"], errors="raise")
    if prices.duplicated(["ticker", "date"]).any():
        raise ValueError("duplicate price row key")
    prices = prices.sort_values(["ticker", "date"])
    prices["price_row"] = prices.groupby("ticker").cumcount() + 1
    positions = prices.set_index(["ticker", "date"])["price_row"]
    rows = []
    for anomaly_id, anomaly in anomalies.reset_index(drop=True).iterrows():
        anomaly_id += 1
        ticker_panel = panel[panel["ticker"].eq(anomaly["ticker"])]
        direct = ticker_panel[
            ticker_panel["next_rebalance_date"].notna()
            & ticker_panel["rebalance_date"].lt(anomaly["quote_date"])
            & ticker_panel["next_rebalance_date"].ge(anomaly["quote_date"])
        ]
        for record in direct.itertuples():
            rows.append(_relationship(record.rebalance_date, record.ticker, anomaly_id, anomaly, "FORWARD_RETURN"))
        key = (anomaly["ticker"], anomaly["quote_date"])
        if key not in positions:
            continue
        anomaly_pos = int(positions.loc[key])
        for record in ticker_panel.itertuples():
            research_key = (record.ticker, record.rebalance_date)
            if research_key not in positions:
                continue
            offset = int(positions.loc[research_key]) - anomaly_pos
            if 0 <= offset <= 58:
                # At offset 19/59 the 20/60-row inclusive frame begins on
                # the post-event quote, so no pre-event price basis remains.
                if offset <= 18:
                    rows.append(_relationship(record.rebalance_date, record.ticker, anomaly_id, anomaly, "MA20", offset))
                rows.append(_relationship(record.rebalance_date, record.ticker, anomaly_id, anomaly, "MA60", offset))
    return pd.DataFrame(rows)


def _relationship(rebalance_date, ticker, anomaly_id, anomaly, quality_component, rows_after=None):
    return {
        "rebalance_date": pd.Timestamp(rebalance_date), "ticker": str(ticker),
        "quality_component": quality_component, "anomaly_id": int(anomaly_id),
        "anomaly_ticker": str(anomaly["ticker"]), "anomaly_date": pd.Timestamp(anomaly["quote_date"]),
        "anomaly_return": float(anomaly["adjusted_return"]),
        "anomaly_source": anomaly["anomaly_source"], "quality_reason": anomaly["anomaly_reason"],
        "rows_after_anomaly": rows_after,
    }


def apply_quality_layer(panel: pd.DataFrame, relationships: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Left-attach flags; never drop or reorder formation observations."""
    original = validate_research_panel(panel)
    result = original.copy()
    result["forward_return_quality"] = np.where(
        result["forward_return_eligible"].fillna(False)
        & np.isfinite(pd.to_numeric(result["forward_return"], errors="coerce")), "VALID", "UNKNOWN"
    )
    for component, feature in (("MA20", "price_ma20_gap"), ("MA60", "price_ma60_gap")):
        result[f"{component.lower()}_quality"] = np.where(
            np.isfinite(pd.to_numeric(result[feature], errors="coerce")), "VALID", "UNKNOWN"
        )
    normalized = relationships.copy()
    if len(normalized):
        normalized["rebalance_date"] = pd.to_datetime(normalized["rebalance_date"], errors="raise")
        normalized["anomaly_date"] = pd.to_datetime(normalized["anomaly_date"], errors="raise")
        normalized["ticker"] = normalized["ticker"].astype(str)
        valid_components = {"FORWARD_RETURN", "MA20", "MA60"}
        if not set(normalized["quality_component"]).issubset(valid_components):
            raise ValueError("unknown quality component")
        if normalized.duplicated(OBSERVATION_KEY + ["quality_component", "anomaly_id"]).any():
            raise ValueError("duplicate anomaly/observation/component relationship")
        for component, flag in (
            ("FORWARD_RETURN", "forward_return_quality"),
            ("MA20", "ma20_quality"), ("MA60", "ma60_quality"),
        ):
            invalid_keys = normalized.loc[normalized["quality_component"].eq(component), OBSERVATION_KEY].drop_duplicates()
            invalid_index = pd.MultiIndex.from_frame(invalid_keys)
            result_index = pd.MultiIndex.from_frame(result[OBSERVATION_KEY])
            result.loc[result_index.isin(invalid_index), flag] = "INVALID"
    result["forward_return_research"] = pd.to_numeric(result["forward_return"], errors="coerce").where(
        result["forward_return_quality"].eq("VALID")
    )
    provenance = _aggregate_provenance(normalized)
    if len(provenance):
        result = result.merge(provenance, on=OBSERVATION_KEY, how="left", validate="one_to_one", sort=False)
    else:
        for column in ("quality_reason", "anomaly_ticker", "anomaly_date", "anomaly_return", "anomaly_source"):
            result[column] = None
    if len(result) != len(original) or list(result[OBSERVATION_KEY].itertuples(index=False, name=None)) != list(original[OBSERVATION_KEY].itertuples(index=False, name=None)):
        raise AssertionError("quality layer changed research membership or ordering")
    for flag in ("forward_return_quality", "ma20_quality", "ma60_quality"):
        if not set(result[flag]).issubset(QUALITY_VALUES):
            raise AssertionError(f"invalid value in {flag}")
    return result, normalized


def _aggregate_provenance(relationships: pd.DataFrame) -> pd.DataFrame:
    if relationships.empty:
        return pd.DataFrame(columns=OBSERVATION_KEY)
    rows = []
    for key, group in relationships.sort_values(["anomaly_date", "quality_component", "anomaly_id"]).groupby(OBSERVATION_KEY, sort=False):
        payload = group[["quality_component", "anomaly_id", "anomaly_ticker", "anomaly_date", "anomaly_return", "anomaly_source", "quality_reason"]].copy()
        payload["anomaly_date"] = payload["anomaly_date"].dt.strftime("%Y-%m-%d")
        records = payload.to_dict("records")
        rows.append({
            "rebalance_date": key[0], "ticker": key[1],
            "quality_reason": json.dumps(records, ensure_ascii=False, sort_keys=True),
            "anomaly_ticker": json.dumps(sorted(set(group["anomaly_ticker"])), ensure_ascii=False),
            "anomaly_date": json.dumps(sorted({d.strftime("%Y-%m-%d") for d in group["anomaly_date"]})),
            "anomaly_return": json.dumps([float(x) for x in group["anomaly_return"]]),
            "anomaly_source": json.dumps(sorted(set(group["anomaly_source"])), ensure_ascii=False),
        })
    return pd.DataFrame(rows)


def assign_revenue_yoy_quintiles(panel: pd.DataFrame) -> pd.DataFrame:
    """Exact canonical 2018-2025 notebook formation: rank before return eligibility."""
    frame = panel.copy()
    frame["yoy_growth"] = pd.to_numeric(frame["yoy_growth"], errors="coerce")
    formation = frame[np.isfinite(frame["yoy_growth"])].copy()
    keep = pd.Series(False, index=formation.index)
    for _, group in formation.groupby("rebalance_date", sort=True):
        values = group["yoy_growth"]
        lo, hi = values.quantile(0.01), values.quantile(0.99)
        keep.loc[group.index] = values.between(lo, hi)
    formation = formation.loc[keep].copy()
    formation["group"] = np.nan
    for _, group in formation.groupby("rebalance_date", sort=True):
        ordered = group.sort_values(["yoy_growth", "ticker"], kind="mergesort")
        if len(ordered) < 10 or ordered["yoy_growth"].nunique() < 5:
            continue
        positions = pd.Series(np.arange(1, len(ordered) + 1), index=ordered.index)
        bins = pd.qcut(positions, q=5, labels=False, duplicates="raise") + 1
        formation.loc[bins.index, "group"] = bins.astype(float)
    formation = formation.dropna(subset=["group"]).copy()
    formation["group"] = formation["group"].astype(int)
    formation["portfolio"] = "Q" + formation["group"].astype(str)
    return formation
