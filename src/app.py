import logging
import os
import sys

import sentry_sdk
from flask import Flask

logging.basicConfig(
    stream=sys.stdout,
    format="%(levelname)s:%(module)s:%(funcName)s:%(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)


def sentry_init():  # pragma: no cover
    """Initialize sentry only if SENTRY_DSN is present"""
    if sentry_dns := os.getenv("SENTRY_DSN"):
        # Initialize Sentry SDK for error logging
        sentry_sdk.init(
            dsn=sentry_dns,
            # Set traces_sample_rate to 1.0 to capture 100%
            # of transactions for performance monitoring.
            traces_sample_rate=1.0,
            # Set profiles_sample_rate to 1.0 to profile 100%
            # of sampled transactions.
            # We recommend adjusting this value in production.
            profiles_sample_rate=1.0,
        )
        logger.info("Sentry initialized")


app = Flask("PROJECT_NAME")
sentry_init()
