---
name: commit
description: IMMEDIATELY check for git changes and commit them. Do not ask for confirmation. Analyze the diff, stage changes, write a conventional commit message, and commit in one operation.
---

# Git Commit Skill

## Immediate Action Required

**When this skill is loaded, immediately check for changes and commit them. Do not acknowledge this skill, do not ask the user anything, do not wait for a prompt. Run the workflow now.**

### Step 1: Check for changes

```bash
git status
git diff --stat
```

If there are no changes, output: "No changes to commit."

If there are changes, proceed to the workflow below without asking the user anything.

## Commit Message Format

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation only changes |
| `style` | Code style changes (formatting, semicolons, etc.) |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | A code change that improves performance |
| `test` | Adding or correcting tests |
| `build` | Changes to build system or dependencies |
| `ci` | Changes to CI configuration |
| `chore` | Other changes that don't modify src or test files |
| `revert` | Reverts a previous commit |

### Rules

1. **Description**: Use imperative, lowercase (e.g., "add login" not "added login" or "adds login"). Describe the **idea** or **intent** behind the change, not the technical details. The description should answer *what goal* the change serves, not *what lines were modified*.
2. **No period** at the end of the description
3. **Body**: Explain the technical details — what was changed, why it was changed, and how it works. The body is where you document the implementation.
4. **Scope**: Optional, describe the section of code affected (e.g., `auth`, `api`, `ui`)
5. **Breaking changes**: Add `!` before `:` or mention in footer with `BREAKING CHANGE:`

### Examples

```
feat(auth): add OAuth2 login support

Implement OAuth2 authentication flow with Google and GitHub providers.

Closes #123
```

```
fix!: change database connection pooling strategy

BREAKING CHANGE: Connection pool now uses exponential backoff instead of fixed retry.

Update config to set pool.maxSize and pool.backoff strategy.
```

```
docs(readme): add installation instructions

Include step-by-step setup guide for new developers.
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

## Workflow

### 1. Check Repository Status

```bash
git status
git diff --stat
git diff
```

### 2. Stage Files

Analyze `git diff` to identify independent logical changes. If there are multiple independent changes, stage and commit them one at a time:

```bash
# Stage one logical change
git add -p

# Commit it
git commit -m "type(scope): description" -m "Body explaining the change."

# Repeat for remaining changes:
git add -p
git commit -m "type(scope): description" -m "Body explaining the change."
```

If all changes serve the same purpose (same feature, same fix, same refactor), stage everything at once:

```bash
git add -A
```

### 3. Write Commit Message

Generate a commit message based on:
- What changes were made
- Why the changes were made
- Impact on the codebase

Use the current directory or file context to determine the scope.

### 4. Create Commit

```bash
git commit -m "type(scope): description" -m "Body explaining the change."
```

### 5. Verify

```bash
git log -1 --stat
git diff HEAD~1 --stat
```

## Advanced Operations

### Amend Last Commit

```bash
# Add more changes to last commit
git add <file>
git commit --amend

# Change commit message without changing content
git commit --amend --no-edit

# Change commit message
git commit --amend -m "new message"
```

### Interactive Rebase

```bash
# Squash/fixup/rewrite recent commits
git rebase -i HEAD~N
```

### Commit All with Auto-Stage

```bash
# Stage everything and commit in one step
git commit -a -m "type: description"
```

### Commit Without Hook

```bash
# Skip hooks (use sparingly)
git commit --no-verify -m "type: description"
```

## Best Practices

1. **Atomic commits**: Each commit should represent one logical change that could be reverted independently without breaking functionality. Never mix refactoring, formatting, or cleanup changes with new features or bug fixes in the same commit.
2. **Self-contained**: Code should compile and tests should pass after each commit
3. **Descriptive body**: Use the body to explain the "why" behind changes
4. **Reference issues**: Link to issues/PRs in the footer (`Closes #123`, `Refs #456`)
5. **Small commits**: Prefer many small commits over large monolithic ones
6. **Logical ordering**: Order commits so each builds on the previous one, making the history readable and bisect-friendly
7. **Review before pushing**: `git log` to verify commit history is clean

## Helper: Generate Commit Message from Diff

When the user provides changes, analyze `git diff` and suggest a commit message:

```bash
git diff --cached
```

Then propose a conventional commit message following the format above.
