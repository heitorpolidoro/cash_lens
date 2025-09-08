
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional, Any
from datetime import datetime
import os

from catboost import CatBoostClassifier
import pandas as pd

MODEL_PATH = os.environ.get("PY_MODEL_PATH", "ml/ml_models/catboost_transaction_classifier.cbm")
K_DEFAULT = int(os.environ.get("PY_TRAIN_K", "1000"))

app = FastAPI(title="CashLens ML Service", version="0.1.0")

class TrainRequest(BaseModel):
    k: Optional[int] = None

class PredictRequest(BaseModel):
    datetime: datetime
    amount: float
    reason: str

class PredictResponse(BaseModel):
    category_id: int

# Data access via Postgres using env from docker-compose
import psycopg2

def get_db_conn():
    return psycopg2.connect(
        dbname=os.getenv("POSTGRES_DB", "cash_lens"),
        user=os.getenv("POSTGRES_USER", "your-postgres-user"),
        password=os.getenv("POSTGRES_PASSWORD", "your-postgres-password"),
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=int(os.getenv("POSTGRES_PORT", "5454")),
    )


def load_transactions(k: int):
    rows = get_transactions(k)
    # rows: list of tuples
    cols = ["datetime", "amount", "reason", "category_id"]
    df = pd.DataFrame(rows, columns=cols)
    return df


def get_transactions(k: int) -> Any:
    sql = """
          SELECT t.datetime, t.amount, t.reason, t.category_id
          FROM transactions t
          WHERE t.category_id IS NOT NULL
          ORDER BY t.datetime DESC
              LIMIT %s \
          """
    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, (k,))
            rows = cur.fetchall()
    return rows


def build_features(df: pd.DataFrame) -> pd.DataFrame:
    dt = pd.to_datetime(df["datetime"], utc=True)
    df_feat = pd.DataFrame()
    df_feat["weekday"] = dt.dt.weekday
    df_feat["day"] = dt.dt.day
    df_feat["time_minute"] = dt.dt.hour * 60 + dt.dt.minute
    # amount as float
    df_feat["amount"] = df["amount"].astype(float)
    # reason as text categorical
    df_feat["reason"] = df["reason"].fillna("")
    return df_feat


def get_model() -> CatBoostClassifier:
    model = CatBoostClassifier()
    return model

@app.post("/train")
def train(req: TrainRequest):
    start = datetime.now()
    k = req.k or K_DEFAULT
    df = load_transactions(k)
    if len(df) < 2:
        raise HTTPException(status_code=400, detail="No enough transactions to train")
    X = build_features(df)
    y = df["category_id"].astype(int)

    model = get_model()
    # CatBoost can handle categorical features; mark 'reason' as categorical
    cat_features = [X.columns.get_loc("reason")]
    model.set_params(loss_function="MultiClass", verbose=False, random_seed=42)

    # Feature weights per column as requested
    feature_weight_map = {
        "weekday": 1.0,
        "day": 0.5,
        "time_minute": 1.0,
        "amount": 1.0,
        "reason": 10.0,
    }
    feature_weights = [feature_weight_map[col] for col in X.columns]

    model.set_params(feature_weights=feature_weights)
    model.fit(X, y, cat_features=cat_features)

    os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
    model.save_model(MODEL_PATH)
    score = model.score(X, y)
    return {"status": "ok", "trained_on": len(df), "accuracy": score, "time": datetime.now() - start}


def ensure_model_loaded() -> CatBoostClassifier:
    if not os.path.exists(MODEL_PATH):
        raise HTTPException(status_code=404, detail="Model file not found. Train first.")
    model = CatBoostClassifier()
    model.load_model(MODEL_PATH)
    return model

@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    model = ensure_model_loaded()
    df = pd.DataFrame([
        {
            "datetime": req.datetime,
            "amount": req.amount,
            "reason": req.reason,
        }
    ])
    X = build_features(df)
    # Predict returns class index; our y were category_id labels, CatBoost returns exact labels if provided as int
    pred = model.predict(X)
    # pred can be shape (1,1) or array; normalize
    try:
        val = int(pred[0])
    except Exception:
        val = int(pred)
    return PredictResponse(category_id=val)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=int(os.getenv("PY_SERVICE_PORT", "8000")), reload=True)
