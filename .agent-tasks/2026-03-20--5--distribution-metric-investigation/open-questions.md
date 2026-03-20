# Open Questions

1. **Should min/max be tracked and exported?** The OTLP Histogram spec supports optional min/max fields. Adding them would require tracking min/max per tag set in the ETS table (not per bucket). This would be a feature addition, not just a bug fix.

2. **Should sum use float instead of round()?** Currently `round(value)` is used for the ETS counter operation which requires integers. An alternative would be to store the sum separately as a float, but this would require changing the ETS update pattern.

3. **Are the default buckets appropriate?** The default buckets `[0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]` have very wide gaps at higher values (e.g., 500-750 is a 250ms range). Users can customize via `reporter_options: [buckets: [...]]` but the defaults may be too coarse for many use cases.
