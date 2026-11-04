---
name: commit-staged
description: IMMEDIATELY commit already-staged changes without asking. Review what is staged, write a conventional commit message, and commit. Do not stage any new files. Do not ask for permission.
---

# Commit Staged Changes

**When this skill is loaded, immediately check for staged changes and commit them. Do not acknowledge this skill, do not ask the user anything, do not wait for a prompt — just do it.**

Commit only the changes that are **already staged** in the git index. Do **not** stage any new or modified files.

## Workflow

### 1. Review Staged Changes

```bash
# See what is staged
git diff --cached --stat

# See staged diff
git diff --cached

# See current status
git status
```

If nothing is staged, output: "Nothing staged."

If something is staged, proceed to commit without asking the user anything.

### 2. Create Commit

```bash
git commit -m "type(scope): description" -m "Body explaining the change."
```

### 3. Verify

```bash
git log -1 --stat
git status
```

## Commit Message Format

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <description>

[optional body]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation only changes |
| `style` | Formatting, semicolons, etc. |
| `refactor` | Code change, neither bug fix nor feature |
| `perf` | Performance improvement |
| `test` | Adding or correcting tests |
| `build` | Build system or dependencies |
| `ci` | CI configuration changes |
| `chore` | Other changes |
| `revert` | Revert a previous commit |

### Rules

1. **Description**: Use imperative, lowercase (e.g., "add login" not "added login" or "adds login"). Describe the **idea** or **intent** behind the change, not the technical details. The description should answer *what goal* the change serves, not *what lines were modified*.
2. **No period** at the end of the description
3. **Scope**: Optional, the affected area (e.g., `auth`, `api`, `ui`)
4. **Body**: Explain the technical details — what was changed, why it was changed, and how it works. The body is where you document the implementation.
5. **Breaking changes**: Add `!` before `:` or use `BREAKING CHANGE:` footer

### Examples

```
feat(auth): add OAuth2 login support

Implement OAuth2 authentication flow with Google and GitHub providers.

Closes #123
```

```
fix(api): handle null response from upstream service

Add null check and fallback to prevent crashes.
```

```
chore(deps): bump python from 3.12 to 3.14

Update base Docker images and CI matrix to Python 3.14.
No code changes required; stdlib API is unchanged.
```

### Intent vs. Technical Detail

The description should capture the **why** — the goal or intent. Technical details belong in the body.

| Bad Description | Better Description |
|-----------------|-------------------|
| `chore(docker): remove -q flag and extensions config` | `chore(docker): drop unused IDE integrations` |
| `fix: change db connection pooling from fixed to exponential backoff` | `fix: improve database connection resilience` |
| `docs: update README with new docker setup steps` | `docs: simplify docker setup instructions` |

The body explains the technical *how*: what was removed, what was changed, and the specifics of the implementation.

## Important Rules

- **NEVER** run `git add` or `git add -p`
- **NEVER** run `git commit -a` or `git commit --all`
- Only commit what is already in the index
- If nothing is staged, inform the user and stop

## Helper: Check Staged vs Unstaged

To show the user what's staged vs what's not:

```bash
# Staged changes
git diff --cached --stat

# Unstaged changes (for reference only, do not stage)
git diff --stat
```
