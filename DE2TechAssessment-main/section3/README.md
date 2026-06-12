# Section 3: System Design

Two designs, each in its own folder:

- **[design1/](design1/)** — access strategy for the section 2 sales
  database: PostgreSQL group roles implementing least privilege for the
  Logistics, Analytics, and Sales teams, with column-level grants and an
  integration test (20 assertions) proving every allow and every deny.
- **[design2/](design2/)** — AWS architecture for an image-processing
  company: dual ingestion (user-facing API + engineer-managed Kafka via
  MSK), event-driven container processing, 7-day compliance purge via S3
  lifecycle rules, and an Athena/QuickSight BI layer. Diagram provided as
  `architecture.drawio` with a mermaid mirror in the README.
