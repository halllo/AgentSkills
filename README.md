# Agent Skills

Some helpful agent skills for VS Code Copilot and Claude.

| Skill | Description |
|---|---|
| `azure-boards` | Work with Azure DevOps Product Backlog Items using az boards CLI |
| `azure-create-pr` | Push a feature branch and create an Azure DevOps pull request via az CLI |
| `azure-read-pr` | Read Azure DevOps pull requests and changed code via az CLI |

## Setup

Clone this project directly into $HOME:

```zsh
cd ~
git clone https://github.com/halllo/AgentSkills.git .agents
```

To use these skills with Claude, symlink them into `~\.claude\skills\`:

```zsh
ln -s "$HOME/.agents/skills/azure-boards"   "$HOME/.claude/skills/azure-boards"
ln -s "$HOME/.agents/skills/azure-create-pr" "$HOME/.claude/skills/azure-create-pr"
ln -s "$HOME/.agents/skills/azure-read-pr"  "$HOME/.claude/skills/azure-read-pr"
```

```cmd
mklink /J "%USERPROFILE%\.claude\skills\azure-boards" "%USERPROFILE%\.agents\skills\azure-boards"
mklink /J "%USERPROFILE%\.claude\skills\azure-create-pr" "%USERPROFILE%\.agents\skills\azure-create-pr"
mklink /J "%USERPROFILE%\.claude\skills\azure-read-pr" "%USERPROFILE%\.agents\skills\azure-read-pr"
```
