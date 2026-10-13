# Agency Agents

`.claude/agents/` contains 282 Claude Code subagents from
[msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents)
(commit `4bce55a`, MIT license — see `AGENCY-AGENTS-LICENSE`).

Claude Code loads them automatically in this repository. Ask for one by name,
e.g. "use the Security Engineer agent to review the wallet code".

To update:

```bash
git clone --depth 1 https://github.com/msitarzewski/agency-agents.git /tmp/agency-agents
/tmp/agency-agents/scripts/install.sh --tool claude-code --no-interactive --path "$PWD/.claude/agents"
```

To install for every project on your own machine, run the same script without `--path`
(installs to `~/.claude/agents/`).
