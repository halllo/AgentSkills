# Skills

Custom agent skills for VS Code Copilot and Claude.

| Skill | Description |
|---|---|
| `azure-boards` | Work with Azure DevOps Product Backlog Items using az boards CLI |
| `azure-create-pr` | Push a feature branch and create an Azure DevOps pull request via az CLI |
| `azure-read-pr` | Read Azure DevOps pull requests and changed code via az CLI |

## Setup

To use these skills with Claude, symlink them into `~\.claude\skills\`:

```cmd
mklink /J "%USERPROFILE%\.claude\skills\azure-boards" "%USERPROFILE%\.agents\skills\azure-boards"
mklink /J "%USERPROFILE%\.claude\skills\azure-create-pr" "%USERPROFILE%\.agents\skills\azure-create-pr"
mklink /J "%USERPROFILE%\.claude\skills\azure-read-pr" "%USERPROFILE%\.agents\skills\azure-read-pr"
```
