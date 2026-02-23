import argparse
import logging
import sys


def setup_logging(verbose_level):
    # 1. Create a root logger
    logger = logging.getLogger()
    logger.setLevel(
        logging.DEBUG
    )  # Set to lowest level so all logs pass to handlers

    # 2. Define formats
    file_formatter = logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )
    console_formatter = logging.Formatter("%(levelname)s: %(message)s")

    # 3. File Handler (Saves everything)
    file_handler = logging.FileHandler("app_debug.log", mode="w")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(file_formatter)
    logger.addHandler(file_handler)

    # 4. Console Handler (Level based on CLI)
    console_handler = logging.StreamHandler(sys.stdout)

    # Map CLI verbosity to Logging levels
    if verbose_level >= 2:
        console_handler.setLevel(logging.DEBUG)
    elif verbose_level == 1:
        console_handler.setLevel(logging.INFO)
    else:
        console_handler.setLevel(logging.WARNING)

    console_handler.setFormatter(console_formatter)
    logger.addHandler(console_handler)


logger = logging.getLogger(__name__)


def main():
    # Setup Argument Parser
    parser = argparse.ArgumentParser(description="Logging Demo")
    parser.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="Increase output verbosity (-v for INFO, -vv for DEBUG)",
    )

    args = parser.parse_args()

    # Initialize Logging
    setup_logging(args.verbose)

    # Test the logs
    logging.debug("This goes ONLY to the file (unless -vv is used)")
    logging.info("This goes to file, and to console if -v is used")
    logging.warning("This goes to both file and console by default")
    logging.error("This is an error message")

    logger.debug("This goes ONLY to the file (unless -vv is used)")
    logger.info("This goes to file, and to console if -v is used")
    logger.warning("This goes to both file and console by default")
    logger.error("This is an error message")


if __name__ == "__main__":
    main()
