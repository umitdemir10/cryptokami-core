# Agency Agents

`.claude/agents/` contains 20 Claude Code subagents picked for this project from
[msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents)
(commit `4bce55a`, MIT license, see `AGENCY-AGENTS-LICENSE`). The rest of the
collection was removed so their descriptions don't fill every session's context.

| Area | Agents |
|---|---|
| Security | Blockchain Security Auditor, Security Architect, Application Security Engineer, Penetration Tester, Secrets & Credential Hygiene Engineer, Threat Detection Engineer, Code Reviewer |
| Architecture | Software Architect, Backend Architect, Database Optimizer, Minimal Change Engineer |
| Operations | DevOps Automator, SRE (Site Reliability Engineer), Incident Response Commander, Git Workflow Master |
| Testing | Reality Checker, API Tester, Performance Benchmarker |
| Docs | Technical Writer, Codebase Onboarding Engineer |

Claude Code loads them automatically in this repository. Ask for one by name,
e.g. "use the Blockchain Security Auditor to review the txp changes".

To add one more agent, copy its file from the upstream repo:

```bash
git clone --depth 1 https://github.com/msitarzewski/agency-agents.git /tmp/agency-agents
find /tmp/agency-agents -name '<agent-file>.md' -exec cp {} .claude/agents/ \;
```
