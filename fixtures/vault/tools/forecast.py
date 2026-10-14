"""Rough November–December forecast for Arc. Run: python3 forecast.py"""

LAUNCH_UNITS = 3000
DTC_SHARE = 0.80
RETAIL_MARGIN = 0.42
RETURNS = 0.03


def revenue(units: int, asp: float) -> float:
    dtc = units * DTC_SHARE * asp
    retail = units * (1 - DTC_SHARE) * asp * (1 - RETAIL_MARGIN)
    return (dtc + retail) * (1 - RETURNS)


def main() -> None:
    for units in (2000, 2500, 3000, 3500):
        # TODO: read ASP from the model instead of hardcoding it.
        asp = 229
        print(f"{units:>5} units  ${revenue(units, asp):>10,.0f}")


if __name__ == "__main__":
    main()
