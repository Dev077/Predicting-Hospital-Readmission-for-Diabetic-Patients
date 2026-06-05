import argparse
import json
import os
import tempfile
from pathlib import Path
from typing import Dict, Tuple

import joblib
import numpy as np
import pandas as pd
import torch
import torch.nn.functional as F
from google.cloud import storage
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.metrics import (
    average_precision_score,
    balanced_accuracy_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data_path", type=str, required=True)
    parser.add_argument("--target_col", type=str, default="target")
    parser.add_argument("--test_size", type=float, default=0.2)
    parser.add_argument("--epochs", type=int, default=25)
    parser.add_argument("--batch_size", type=int, default=64)
    parser.add_argument("--learning_rate", type=float, default=1e-3)
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--model_dir", type=str, default="./outputs")
    return parser.parse_args()


def make_one_hot_encoder() -> OneHotEncoder:
    try:
        return OneHotEncoder(handle_unknown="ignore", sparse_output=False)
    except TypeError:
        return OneHotEncoder(handle_unknown="ignore", sparse=False)


def build_preprocessor(df: pd.DataFrame) -> Tuple[ColumnTransformer, np.ndarray]:
    categorical_cols = df.select_dtypes(include=["object"]).columns.tolist()
    numeric_cols = [c for c in df.columns if c not in categorical_cols]

    preprocessor = ColumnTransformer(
        transformers=[
            (
                "num",
                Pipeline([
                    ("imputer", SimpleImputer(strategy="median")),
                    ("scaler", StandardScaler()),
                ]),
                numeric_cols,
            ),
            (
                "cat",
                Pipeline([
                    ("imputer", SimpleImputer(strategy="most_frequent")),
                    ("onehot", make_one_hot_encoder()),
                ]),
                categorical_cols,
            ),
        ]
    )
    x_processed = preprocessor.fit_transform(df)
    return preprocessor, x_processed


def init_parameters(input_dim: int) -> Dict[str, torch.Tensor]:
    h1 = 128
    h2 = 64

    w1 = torch.randn(input_dim, h1, dtype=torch.float32) * np.sqrt(2.0 / input_dim)
    b1 = torch.zeros(h1, dtype=torch.float32)

    w2 = torch.randn(h1, h2, dtype=torch.float32) * np.sqrt(2.0 / h1)
    b2 = torch.zeros(h2, dtype=torch.float32)

    w3 = torch.randn(h2, 1, dtype=torch.float32) * np.sqrt(2.0 / h2)
    b3 = torch.zeros(1, dtype=torch.float32)

    params = {
        "w1": w1.requires_grad_(True),
        "b1": b1.requires_grad_(True),
        "w2": w2.requires_grad_(True),
        "b2": b2.requires_grad_(True),
        "w3": w3.requires_grad_(True),
        "b3": b3.requires_grad_(True),
    }
    return params


def forward_pass(
    x: torch.Tensor,
    params: Dict[str, torch.Tensor],
    training: bool,
) -> torch.Tensor:
    # Manual tensor operations with explicit weights/biases.
    z1 = x @ params["w1"] + params["b1"]
    a1 = F.relu(z1)
    a1 = F.dropout(a1, p=0.3, training=training)

    z2 = a1 @ params["w2"] + params["b2"]
    a2 = F.relu(z2)
    a2 = F.dropout(a2, p=0.2, training=training)

    logits = a2 @ params["w3"] + params["b3"]
    return logits


def train_model(
    params: Dict[str, torch.Tensor],
    x_train: torch.Tensor,
    y_train: torch.Tensor,
    epochs: int,
    batch_size: int,
    learning_rate: float,
) -> None:
    optimizer = torch.optim.Adam(list(params.values()), lr=learning_rate)

    for epoch in range(epochs):
        permutation = torch.randperm(x_train.size(0))
        epoch_loss = 0.0

        for start in range(0, x_train.size(0), batch_size):
            indices = permutation[start : start + batch_size]
            batch_x = x_train[indices]
            batch_y = y_train[indices]

            optimizer.zero_grad()
            logits = forward_pass(batch_x, params, training=True)
            loss = F.binary_cross_entropy_with_logits(logits, batch_y)
            loss.backward()
            optimizer.step()

            epoch_loss += loss.item() * batch_x.size(0)

        epoch_loss /= x_train.size(0)
        print(f"Epoch {epoch + 1:02d}/{epochs} - loss: {epoch_loss:.4f}")


def evaluate(
    params: Dict[str, torch.Tensor],
    x_test: torch.Tensor,
    y_test: torch.Tensor,
    threshold: float,
) -> Tuple[np.ndarray, Dict[str, float]]:
    with torch.no_grad():
        logits = forward_pass(x_test, params, training=False)
        probs = torch.sigmoid(logits).cpu().numpy().ravel()

    y_true = y_test.cpu().numpy().ravel().astype(int)
    y_pred = (probs >= threshold).astype(int)

    cm = confusion_matrix(y_true, y_pred)
    tn, fp, fn, tp = cm.ravel()

    specificity = float(tn / (tn + fp)) if (tn + fp) > 0 else 0.0
    metrics = {
        "precision": float(precision_score(y_true, y_pred, zero_division=0)),
        "recall": float(recall_score(y_true, y_pred, zero_division=0)),
        "f1": float(f1_score(y_true, y_pred, zero_division=0)),
        "specificity": specificity,
        "balanced_accuracy": float(balanced_accuracy_score(y_true, y_pred)),
        "roc_auc": float(roc_auc_score(y_true, probs)),
        "pr_auc": float(average_precision_score(y_true, probs)),
    }
    return cm, metrics


def parse_gs_uri(uri: str) -> Tuple[str, str]:
    no_scheme = uri.replace("gs://", "", 1)
    parts = no_scheme.split("/", 1)
    bucket = parts[0]
    prefix = parts[1] if len(parts) > 1 else ""
    return bucket, prefix.rstrip("/")


def upload_dir_to_gcs(local_dir: Path, gcs_uri: str) -> None:
    bucket_name, prefix = parse_gs_uri(gcs_uri)
    client = storage.Client()
    bucket = client.bucket(bucket_name)

    for path in local_dir.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(local_dir).as_posix()
        blob_path = f"{prefix}/{relative}" if prefix else relative
        bucket.blob(blob_path).upload_from_filename(str(path))
        print(f"Uploaded gs://{bucket_name}/{blob_path}")


def main() -> None:
    args = parse_args()
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    df = pd.read_csv(args.data_path)
    if args.target_col not in df.columns:
        raise ValueError(f"Target column '{args.target_col}' not found in dataset")

    y = df[args.target_col].astype(int).to_numpy()
    x_df = df.drop(columns=[args.target_col]).drop(
        columns=[c for c in ["encounter_id", "patient_nbr"] if c in df.columns],
        errors="ignore",
    )

    preprocessor, x_processed = build_preprocessor(x_df)

    x_train, x_test, y_train, y_test = train_test_split(
        x_processed,
        y,
        test_size=args.test_size,
        random_state=args.seed,
        stratify=y,
    )

    x_train_t = torch.tensor(x_train, dtype=torch.float32)
    x_test_t = torch.tensor(x_test, dtype=torch.float32)
    y_train_t = torch.tensor(y_train, dtype=torch.float32).unsqueeze(1)
    y_test_t = torch.tensor(y_test, dtype=torch.float32).unsqueeze(1)

    params = init_parameters(x_train_t.shape[1])
    train_model(
        params=params,
        x_train=x_train_t,
        y_train=y_train_t,
        epochs=args.epochs,
        batch_size=args.batch_size,
        learning_rate=args.learning_rate,
    )

    cm, metrics = evaluate(params, x_test_t, y_test_t, args.threshold)

    print("Confusion matrix:")
    print(cm)
    print("Metrics:")
    print(json.dumps(metrics, indent=2))

    out_dir = Path(tempfile.mkdtemp())
    torch.save({k: v.detach().cpu() for k, v in params.items()}, out_dir / "model_parameters.pt")
    joblib.dump(preprocessor, out_dir / "preprocessor.joblib")

    pd.DataFrame(
        cm,
        index=["actual_0", "actual_1"],
        columns=["pred_0", "pred_1"],
    ).to_csv(out_dir / "confusion_matrix.csv")

    with open(out_dir / "metrics.json", "w", encoding="utf-8") as f:
        json.dump(metrics, f, indent=2)

    model_dir = os.environ.get("AIP_MODEL_DIR", args.model_dir)
    if model_dir.startswith("gs://"):
        upload_dir_to_gcs(out_dir, model_dir)
    else:
        target = Path(model_dir)
        target.mkdir(parents=True, exist_ok=True)
        for file_path in out_dir.iterdir():
            if file_path.is_file():
                (target / file_path.name).write_bytes(file_path.read_bytes())

    print(f"Artifacts saved to: {model_dir}")


if __name__ == "__main__":
    main()
