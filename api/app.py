"""This module contains the main application logic."""

import logging
import os
import sys

import sentry_sdk
from flask import Flask
from flask.cli import load_dotenv

logging.basicConfig(
    stream=sys.stdout,
    format="%(levelname)s:%(module)s:%(funcName)s:%(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)


def sentry_init() -> None:  # pragma: no cover
    """Initialize sentry only if SENTRY_DSN is present"""
    if sentry_dsn := os.getenv("SENTRY_DSN"):
        # Initialize Sentry SDK for error logging
        sentry_sdk.init(
            dsn=sentry_dsn,
            # Set traces_sample_rate to 1.0 to capture 100%
            # of transactions for performance monitoring.
            traces_sample_rate=1.0,
            # Set profiles_sample_rate to 1.0 to profile 100%
            # of sampled transactions.
            # We recommend adjusting this value in production.
            profiles_sample_rate=1.0,
        )
        logger.info("Sentry initialized")


app = Flask(__name__)
sentry_init()
# webhook_handler.handle_with_flask(
#     app, use_default_index=False, config_file="../.bartholomew.yaml"
# )

load_dotenv()
# default_configs()


@app.route("/", methods=["GET"])
def index() -> str:  # pragma: no cover
    """Return the index homepage"""
    return "Hello"


