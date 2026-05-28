# syslog-appliance Development Guide

## Project Goal

Build a Rocky Linux-based syslog appliance that can run first as a virtual machine and later as a physical appliance.

## Core Principles

- Keep raw syslog logs as the source of truth.
- Store parsed logs separately for search.
- Do not store secrets in Git.
- All scripts must be safe to run repeatedly.
- All OS-level changes must be documented.
- Do not disable SELinux unless explicitly required.
- Prefer stable and maintainable implementation.
- Use systemd for service management.
- Use firewalld for firewall configuration.
- Use Git commits for each meaningful change.
