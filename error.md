## The Root Problem

Kubernetes YAML files are **static configuration files**. They don't understand variables like `$PROJECT_ID`. When you write:
```yaml
image: us-central1-docker.pkg.dev/$PROJECT_ID/my-repo/my-app:latest
```

Kubernetes reads this **literally** as a string with the dollar sign and text "PROJECT_ID" - not as a variable. It tries to pull an image named `.../$PROJECT_ID/...` which is invalid (contains illegal characters).

## Why Each Attempt Failed

### Attempt 1: Using `sed` with single quotes
```yaml
- name: 'ubuntu'
  args: ['sed', '-i', 's/$PROJECT_ID/$PROJECT_ID/g', 'k8s-deployment.yaml']
```

**Why it failed:**
- In shell, single quotes `'...'` mean "treat everything literally"
- The shell never expanded `$PROJECT_ID` to `docker-479413`
- `sed` literally searched for the 5 characters `$PROJECT_ID` and tried to replace them with the 5 characters `$PROJECT_ID` (no change)

### Attempt 2: Using `sed` with double quotes (first try)
```yaml
- name: 'ubuntu'
  args:
  - 'bash'
  - '-c'
  - |
    sed "s/\$PROJECT_ID/$PROJECT_ID/g" k8s-deployment.yaml > k8s-deployment-expanded.yaml
```

**Why it failed:**
- Cloud Build's YAML parser processes your `cloudbuild.yaml` **before** passing it to the shell
- When the YAML parser sees `\$`, it treats the backslash as an escape character at the YAML level
- By the time bash receives the command, the backslash was already consumed/removed by YAML
- So bash received `s/$PROJECT_ID/docker-479413/g`
- This means `sed` tried to use `$PROJECT_ID` as a **sed variable** (which doesn't exist), not as literal text to search for

### Attempt 3: Using `envsubst`
```yaml
- name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    export PROJECT_ID=$PROJECT_ID
    envsubst < k8s-deployment.yaml > k8s-deployment-expanded.yaml
```

**Why it failed:**
- `envsubst` is a Linux command that replaces environment variables in text files
- **BUT** it's not installed in the Cloud SDK image by default
- The error `bash: line 2: envsubst: command not found` proved this
- Since `envsubst` didn't run, the output file was empty
- `gke-deploy` tried to read an empty file → "no objects found"

### Attempt 4: Using `sed` with triple backslash
```yaml
- name: 'ubuntu'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    sed "s/\\\$PROJECT_ID/$PROJECT_ID/g" k8s-deployment.yaml > k8s-deployment-expanded.yaml
```

**Why it STILL failed:**
Looking at your actual build logs from Step #2, the output showed:
```yaml
image: us-central1-docker.pkg.dev/$PROJECT_ID/my-repo/my-app:latest
```

This means `$PROJECT_ID` was **still not replaced**. Here's what happened:

1. **YAML Parser Layer:** Cloud Build parses your `cloudbuild.yaml`
   - Sees: `s/\\\$PROJECT_ID/...`
   - Processes escape sequences: `\\\` becomes `\\` (one backslash consumed)
   - Passes to bash: `s/\\$PROJECT_ID/docker-479413/g`

2. **Bash Layer:** Bash receives the command
   - Sees: `s/\\$PROJECT_ID/docker-479413/g`
   - Interprets `\\` as an escaped backslash → becomes literal `\`
   - Interprets `$PROJECT_ID` as variable expansion → becomes `docker-479413`
   - Passes to sed: `s/\docker-479413/docker-479413/g`

3. **Sed Layer:** sed receives
   - Searches for: `\docker-479413` (literal backslash + text)
   - This doesn't exist in your file!
   - So sed made zero replacements

The file still had `$PROJECT_ID` because sed was searching for the wrong pattern.

## What Actually Works: Hardcoding

```yaml
image: us-central1-docker.pkg.dev/docker-479413/my-repo/my-app:latest
```

**Why this works:**
1. No variables to substitute
2. No shell escaping complexity
3. No YAML parser interference
4. Kubernetes receives the exact, valid image path directly
5. It immediately pulls the image and starts the container

## The Alternative That WOULD Work

If you absolutely need dynamic substitution, here's the ONE way that works with Cloud Build:

```yaml
- name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    cat k8s-deployment.yaml | \
    sed "s|\$PROJECT_ID|$PROJECT_ID|g" > k8s-deployment-expanded.yaml
```

**Why THIS would work:**
1. Using pipe `|` as the sed delimiter (instead of `/`) avoids conflicts with slashes in URLs
2. The `\$` here actually survives the YAML parser because it's inside a multiline block (`|`)
3. bash expands the second `$PROJECT_ID` to `docker-479413`
4. sed searches for literal `$PROJECT_ID` and replaces it

## Summary of the Escaping Hell

| What You Write | YAML Parser Sees | Bash Receives | Sed Searches For | Result |
|---|---|---|---|---|
| `'s/$PROJECT_ID/$PROJECT_ID/g'` | (single quotes) | `s/$PROJECT_ID/$PROJECT_ID/g` | Literal `$PROJECT_ID` → Literal `$PROJECT_ID` | ❌ No change |
| `"s/\$PROJECT_ID/$PROJECT_ID/g"` | `s/$PROJECT_ID/docker-479413/g` | sed variable `$PROJECT_ID` | sed variable (doesn't exist) | ❌ Pattern not found |
| `"s/\\\$PROJECT_ID/$PROJECT_ID/g"` | `s/\\$PROJECT_ID/docker-479413/g` | `s/\docker-479413/docker-479413/g` | `\docker-479413` | ❌ Wrong pattern |
| Hardcoded `docker-479413` | `docker-479413` | N/A (no substitution) | N/A | ✅ Works! |

The multiple layers (YAML → Bash → Sed) each interpret escape characters differently, making it nearly impossible to get the escaping right. Hardcoding bypasses all of this complexity.
