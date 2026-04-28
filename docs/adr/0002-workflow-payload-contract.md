# 0002 - Workflow payload contract

## Status

Accepted

## Context

Workflow entry data needs to be clear, validated, and readable in the workflow
definition without splitting the contract across multiple concepts.

## Decision

Each workflow trigger defines a `payload` block that acts as the canonical run
input contract.

The payload contract:

- declares required fields and types
- may provide defaults
- is validated before a run is persisted
- is the same contract used by host-application API calls

## Consequences

- workflow definitions stay compact and readable
- host applications work with one input contract per workflow
- trigger defaults can enrich manual or scheduled starts without adding a second input system
- the current runtime supports one trigger per workflow until broader trigger composition is added
