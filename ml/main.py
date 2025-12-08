
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
import os

from catboost import CatBoostClassifier
import pandas as pd
from pymongo import MongoClient

MODEL_PATH = os.environ.get("PY_MODEL_PATH", "ml/ml_models/catboost_transaction_classifier.cbm")
K_DEFAULT = int(os.environ.get("PY_TRAIN_K", "1000"))

app = FastAPI(title="CashLens ML Service", version="0.1.0")

class TrainRequest(BaseModel):
    k: Optional[int] = None

class PredictRequest(BaseModel):
    datetime: datetime
    amount: float
    reason: str

class PredictBatchResponse(BaseModel):
    categories: list[int]

def get_mongo_client():
    mongo_url = os.getenv("MONGODB_URL", "mongodb://mongodb:27017/cash_lens")
    return MongoClient(mongo_url)

def load_transactions(k: int):
    client = get_mongo_client()
    db = client.cash_lens
    
    # Get transactions with category_id
    transactions = list(db.transactions.find(
        {"category_id": {"$exists": True, "$ne": None}},
        {"datetime": 1, "amount": 1, "reason": 1, "category_id": 1}
    ).sort("datetime", -1).limit(k))
    
    if not transactions:
        return pd.DataFrame()
    
    # Convert to DataFrame
    df = pd.DataFrame(transactions)
    client.close()
    return df

def build_features(df: pd.DataFrame) -> pd.DataFrame:
    if df.empty:
        return pd.DataFrame()
    
    dt = pd.to_datetime(df["datetime"])
    df_feat = pd.DataFrame()
    df_feat["weekday"] = dt.dt.weekday
    df_feat["day"] = dt.dt.day
    df_feat["time_minute"] = dt.dt.hour * 60 + dt.dt.minute
    df_feat["amount"] = pd.to_numeric(df["amount"], errors='coerce').fillna(0)
    df_feat["reason"] = df["reason"].fillna("")
    return df_feat

def get_model() -> CatBoostClassifier:
    return CatBoostClassifier()

@app.post("/train")
def train(req: TrainRequest):
    start = datetime.now()
    k = req.k or K_DEFAULT
    df = load_transactions(k)
    
    if len(df) < 2:
        raise HTTPException(status_code=400, detail="Not enough transactions to train")
    
    X = build_features(df)
    y = df["category_id"].astype(int)

    model = get_model()
    cat_features = [X.columns.get_loc("reason")]
    model.set_params(loss_function="MultiClass", verbose=False, random_seed=42)

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
    
    return {
        "status": "ok", 
        "trained_on": len(df), 
        "accuracy": score, 
        "time": str(datetime.now() - start)
    }

def ensure_model_loaded() -> CatBoostClassifier:
    if not os.path.exists(MODEL_PATH):
        raise HTTPException(status_code=404, detail="Model file not found. Train first.")
    model = CatBoostClassifier()
    model.load_model(MODEL_PATH)
    return model

@app.post("/predict", response_model=PredictBatchResponse)
def predict(reqs: List[PredictRequest]):
    model = ensure_model_loaded()
    
    data = [
        {
            "datetime": r.datetime,
            "amount": r.amount,
            "reason": r.reason,
        }
        for r in reqs
    ]
    
    if len(data) == 0:
        raise HTTPException(status_code=400, detail="Empty request list")
    
    df = pd.DataFrame(data)
    X = build_features(df)
    preds = model.predict(X)
    
    try:
        categories = pd.Series(preds).astype(int).tolist()
    except Exception:
        categories = [int(x) for x in (preds.reshape(-1) if hasattr(preds, "reshape") else preds)]
    
    return PredictBatchResponse(categories=categories)

@app.get("/health")
def health():
    try:
        client = get_mongo_client()
        client.admin.command('ping')
        client.close()
        return {"status": "ok", "mongodb": "connected"}
    except Exception as e:
        return {"status": "error", "mongodb": str(e)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=int(os.getenv("PY_SERVICE_PORT", "8000")), reload=True)
