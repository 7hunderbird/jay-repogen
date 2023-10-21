#!/bin/bash

set -e

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# install core and development Python dependencies into the currently activated venv
function install {
    python -m pip install --upgrade pip
    python -m pip install cookiecutter
    python -m pip install pytest pre-commit
}

function generate-project {
    cookiecutter ./ \
        --output-dir "$THIS_DIR/sample"

    cd "$THIS_DIR/sample"
    cd $(ls)
    git init
    git add --all
    git branch -M main
    git commit -m "feature: generated sample project with python-course-cookiecutter-v2"
}

function lint {
    pre-commit run --all-files
}

function lint:ci {
    # We skip no-commit-to-branch since that blocks commits to `main`.
    # All merged PRs are commits to `main` so this must be disabled.
    SKIP=no-commit-to-branch pre-commit run --all-files
}

function test:quick {
    run-tests -m "not slow" ${@:-"$THIS_DIR/tests/"}
}

function run-tests {
    python -m pytest ${@:-"$THIS_DIR/tests/"}
}

# remove all files generated by tests, builds, or operating this codebase
function clean {
    rm -rf dist build coverage.xml test-reports sample/
    find . \
      -type d \
      \( \
        -name "*cache*" \
        -o -name "*.dist-info" \
        -o -name "*.egg-info" \
        -o -name "*htmlcov" \
      \) \
      -not -path "*env/*" \
      -exec rm -r {} + || true

    find . \
      -type f \
      -name "*.pyc" \
      -not -path "*env/*" \
      -exec rm {} +
}

# export the contents of .env as environment variables
function try-load-dotenv {
    if [ ! -f "$THIS_DIR/.env" ]; then
        echo "no .env file found"
        return 1
    fi

    while read -r line; do
        export "$line"
    done < <(grep -v '^#' "$THIS_DIR/.env" | grep -v '^$')
}

# args:
#    REPO_NAME - name of the repository
#    GITHUB_USERNAME - name of the GitHub user; e.g. shilongjaycui
#    IS_PUBLIC_REPO - if true, the repository will be public, otherwise private
function create-repo-if-not-exists {
    local IS_PUBLIC_REPO=${IS_PUBLIC_REPO:-true}

    # check to see if the repository exists; if it does, return
    echo "Checking to see if $GITHUB_USERNAME/$REPO_NAME exists..."
    gh repo view "$GITHUB_USERNAME/$REPO_NAME" > /dev/null \
        && echo "$GITHUB_USERNAME/$REPO_NAME exists. Exiting..." \
        && return 0
    # otherwise we will create the repository
    if [[ "$IS_PUBLIC_REPO" == "true" ]]; then
        PUBLIC_OR_PRIVATE="public"
    else
        PUBLIC_OR_PRIVATE="private"
    fi

    echo "$GITHUB_USERNAME/$REPO_NAME does not exist. Creating..."
    gh repo create "$GITHUB_USERNAME/$REPO_NAME" "--$PUBLIC_OR_PRIVATE"

    push-initial-readme-to-repo
}

function push-initial-readme-to-repo {
    # create a main branch for the repository
    rm -rf "$REPO_NAME"
    gh repo clone "$GITHUB_USERNAME/$REPO_NAME"
    cd "$REPO_NAME"
    echo "# $REPO_NAME" > "README.md"
    git branch -M main || true
    git add --all
    git commit -m "Created repository"
    if [[ -n "$GH_TOKEN" ]]; then
        git remote set-url origin "https://$GITHUB_USERNAME:$GH_TOKEN@github.com/$GITHUB_USERNAME/$REPO_NAME.git"
    fi
    git push origin main
}

function create-sample-repo {
    git add .github/
    git commit -m "Debugged workflow"
    git push origin main

    gh workflow run .github/workflows/create-or-update-repo.yaml \
        -f repo_name=generated-repository \
        -f package_import_name=generated_package \
        --ref main
}

# args:
#    TEST_PYPI_TOKEN, PROD_PYPI_TOKEN - auth token for test & prod PyPI
#    REPO_NAME - name of the repository
#    GITHUB_USERNAME - name of the GitHub user; e.g. shilongjaycui
function configure-repo {
    # Configure GitHub Actions secrets.
    gh secret set TEST_PYPI_TOKEN \
        --body "$TEST_PYPI_TOKEN" \
        --repo "$GITHUB_USERNAME/$REPO_NAME"
    gh secret set PROD_PYPI_TOKEN \
        --body "$PROD_PYPI_TOKEN" \
        --repo "$GITHUB_USERNAME/$REPO_NAME"

    # Protect main branch by enforcing build pass on feature branch before merging.
    BRANCH_NAME="main"
    gh api \
        -X PUT "repos/$GITHUB_USERNAME/$REPO_NAME/branches/$BRANCH_NAME/protection" \
        -H "Accept: application/vnd.github+json" \
        -F "required_status_checks[strict]=true" \
        -F "required_status_checks[checks][][context]=check-version-txt" \
        -F "required_status_checks[checks][][context]=lint-format-and-static-code-checks" \
        -F "required_status_checks[checks][][context]=build-wheel-and-sdist" \
        -F "required_status_checks[checks][][context]=execute-tests" \
        -F "required_pull_request_reviews[required_approving_review_count]=0" \
        -F "enforce_admins=null" \
        -F "restrictions=null" > /dev/null

}

# args:
#    REPO_NAME - name of the repository
#    GITHUB_USERNAME - name of the GitHub user; e.g. shilongjaycui
#    PACKAGE_IMPORT_NAME - name of the package inside the repository
function open-pr-with-generated-project {
    # Install dependencies.
    install

    # Clone the repository.
    gh repo clone "$GITHUB_USERNAME/$REPO_NAME"

    # Delete the repository's contents.
    mv "$REPO_NAME/.git" "./$REPO_NAME.git.bak"
    rm -rf "$REPO_NAME"
    mkdir "$REPO_NAME"
    mv "./$REPO_NAME.git.bak" "$REPO_NAME/.git"

    # Generate the project into the repository's folder.
    OUTDIR="./outdir/"
    CONFIG_FILE_PATH="./$REPO_NAME.yaml"
    cat <<EOF > "$CONFIG_FILE_PATH"
default_context:
    repo_name: $REPO_NAME
    package_import_name: $PACKAGE_IMPORT_NAME
EOF

    cookiecutter ./ \
        --output-dir "$OUTDIR" \
        --no-input \
        --config-file $CONFIG_FILE_PATH
    rm $CONFIG_FILE_PATH

    # Stage the generated files on a new feature branch (to invoke pre-commit).
    mv "$REPO_NAME/.git" "$OUTDIR/$REPO_NAME/"
    cd "$OUTDIR/$REPO_NAME"

    # Make sure that the feature branch's name is unique.
    UUID=$(uuidgen)
    UNIQUE_BRANCH_NAME=populate-from-template-${UUID:0:6}

    git checkout -b "$UNIQUE_BRANCH_NAME"
    git add --all

    # Lint the generated files (with pre-commit).
    lint:ci || true

    # Re-stage the files modified by pre-commit.
    git add --all

    # Commit the changes and push them to the remote feature branch.
    git commit -m "Populated content from the cookiecutter template"
    if [[ -n "$GH_TOKEN" ]]; then
        git remote set-url origin "https://$GITHUB_USERNAME:$GH_TOKEN@github.com/$GITHUB_USERNAME/$REPO_NAME"
    fi
    git push origin "$UNIQUE_BRANCH_NAME"

    # Open a PR from the feature branch into the main branch.
    gh pr create \
        --title "Populated content from the cookiecutter template" \
        --body "This PR was generated by \`jay-repogen\`." \
        --base main \
        --head "$UNIQUE_BRANCH_NAME" \
        --repo "$GITHUB_USERNAME/$REPO_NAME"
}

# print all functions in this file
function help {
    echo "$0 <task> <args>"
    echo "Tasks:"
    compgen -A function | cat -n
}

TIMEFORMAT="Task completed in %3lR"
time ${@:-help}
