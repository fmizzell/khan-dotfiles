#!/bin/bash

# This has files that are used by Khan Academy developers.  This setup
# script is OS-agnostic; it installs things like dotfiles, python
# libraries, etc that are the same on Linux, OS X, maybe even cygwin.
# It is intended to be idempotent; you can safely run it multiple
# times.  It should be run from the root of the khan-dotfiles directory.


# Bail on any errors
set -e

# Install in $HOME by default, but can set an alternate destination via $1.
ROOT=${1-$HOME}
mkdir -p "$ROOT"

# the directory all repositories will be cloned to
REPOS_DIR="$ROOT/khan"

# derived path location constants
DEVTOOLS_DIR="$REPOS_DIR/devtools"
KACLONE_BIN="$DEVTOOLS_DIR/ka-clone/bin/ka-clone"

# Load shared setup functions.
. "$DEVTOOLS_DIR"/khan-dotfiles/shared-functions.sh

# the directory this script exists in, regardless of where it is called from
#
# TODO(mroth): some of the historical parts of this script assume the user is
# running this from within the directory (and they are in fact instructed to do
# so), but it may be worth auditing and removing all CWD requirements in the
# future.
DIR=$(dirname "$0")

# should we install webapp? (disable for mobile devs or to make testing faster)
WEBAPP="${WEBAPP:-true}"

# Will contain a string on a mac and be empty on linux
IS_MAC=$(which sw_vers || echo "")

trap exit_warning EXIT   # from shared-functions.sh

warnings=""

add_warning() {
    echo "WARNING: $*"
    warnings="$warnings\nWARNING: $*"
}

add_fatal_error() {
    err_and_exit "FATAL ERROR: $*"
}

check_dependencies() {
    update "Checking system dependencies"
    ######

    # We need git >=1.7.11 for '[push] default=simple'.
    if ! git --version | grep -q -e 'version 1.7.1[1-9]' \
                                 -e 'version 1.[89]' \
                                 -e 'version 2'; then
        err_and_exit "Must have git >= 1.8.  See http://git-scm.com/downloads"
    fi

    # You need to have run the setup to install binaries: node, npm/etc.
    if ! npm --version >/dev/null; then
        err_and_exit "You must install binaries before running $0. See https://khanacademy.atlassian.net/wiki/x/VgKiC"
    fi
}

install_dotfiles() {
    update "Installing and updating dotfiles (.bashrc, etc)"
    ######

    # Most dotfiles are installed as symlinks.
    # (But we ignore .git/.arc*/etc which are actually part of the repo!)
    #
    # TODO(mroth): for organization, we should keep all dotfiles in a
    # subdirectory, but to make that change will require repairing old symlinks
    # so they don't break when the target moves.
    for file in .*.khan .*.khan-xtra .git_template/commit_template .vim/ftplugin/*.vim; do
        mkdir -p "$ROOT/$(dirname "$file")"
        source=$(pwd)/"$file"
        dest="$ROOT/$file"
        # if dest is already a symlink pointing to correct source, skip it
        if [ -h "$dest" -a "$(readlink "$dest")" = "$source" ]; then
            :
        # else if dest already exists, warn user and skip dotfile
        elif [ -e "$dest" ]; then
            add_warning "Not symlinking to $dest because it already exists."
        # otherwise, verbosely symlink the file (with --force)
        else
            ln -sfvn "$source" "$dest"
        fi
    done

    # A few dotfiles are copied so the user can change them.  They all
    # have names like bashrc.default, which is installed as .bashrc.
    # They all have the property they 'include' khan-specific code.
    for file in *.default; do
        dest="$ROOT/.$(echo "$file" | sed s/.default$//)"  # foo.default -> .foo
        ka_version=.$(echo "$file" | sed s/default/khan/)  # .bashrc.khan, etc.
        if [ ! -e "$dest" ]; then
            cp -f "$file" "$dest"
        elif ! fgrep -q "$ka_version" "$dest"; then
            add_fatal_error "$dest does not 'include' $ka_version;" \
                            "see $(pwd)/$file and add the contents to $dest"
        fi
    done

    # If users are using a shell other than bash, the updates we make won't
    # get picked up.  They'll have to activate the virtualenv in their shell
    # config; if they haven't, the rest of the script will fail.
    # TODO(benkraft): Add more specific instructions for other common shells,
    # or just write dotfiles for them.
    shell="`basename "$SHELL"`"
    if [ -z "$VIRTUAL_ENV" ] && [ "$shell" != bash ] && [ "$shell" != zsh ]; then
        add_fatal_error "Your default shell is $shell, not bash or zsh, so you'll" \
                        "need to update its config manually to activate our" \
                        "virtualenv. You can follow the instructions at" \
                        "khanacademy.org/r/virtualenvs to create a new" \
                        "virtualenv and then export its path in the" \
                        "VIRTUAL_ENV environment variable before trying again."
    fi

    # *.template files are also copied so the user can change them.  Unlike the
    # "default" files above, these do not include KA code, they are merely
    # useful defaults we want to install if the user doesnt have anything
    # already.
    #
    # We should avoid installing anything absolutely not necessary in this
    # category, so for now, this is just a global .gitignore
    for file in *.template; do
        dest="$ROOT/.$(echo "$file" | sed s/.template$//)"  # foo.default -> .foo
        if [ ! -e "$dest" ]; then
            cp -f "$file" "$dest"
        fi
    done

    # Make sure we pick up any changes we've made, so later steps of install don't fail.
    . ~/.profile
}

# clone a repository without any special sauce. should only be used in order to
# bootstrap ka-clone, or if you are certain you don't want a khanified repo.
# $1: url of the repository to clone.  $2: directory to put repo
clone_repo() {
    (
        mkdir -p "$2"
        cd "$2"
        dirname=$(basename "$1")
        if [ ! -d "$dirname" ]; then
            git clone "$1"
            cd "$dirname"
            git submodule update --init --recursive
        fi
    )
}

clone_kaclone() {
    echo "Installing ka-clone tool"
    clone_repo git@github.com:Khan/ka-clone "$DEVTOOLS_DIR"
}

clone_webapp() {
    echo "Cloning main webapp repository"
    # By this point, we must have git and ka-clone working, so a failure likely
    # means the user doesn't have access to webapp (it's the only private repo
    # we clone here) -- we give a more useful error than just "not found".
    kaclone_repo git@github.com:Khan/webapp "$REPOS_DIR/" -p --email="$gitmail" || add_fatal_error \
        "Unable to clone Khan/webapp -- perhaps you don't have access? " \
        "If you can't view https://github.com/Khan/webapp, ask #it in " \
        "Slack to be added."
}

# clones a specific devtool
clone_devtool() {
    kaclone_repo "$1" "$DEVTOOLS_DIR" --email="$gitmail"
    # TODO(mroth): for devtools only, we should try to do:
    #   git pull --quiet --ff-only
    # but need to make sure we do it in master only!
}

# clones all devtools
clone_devtools() {
    echo "Installing devtools"
    clone_devtool git@github.com:Khan/ka-clone    # already cloned, so will --repair the first time
    clone_devtool git@github.com:Khan/khan-linter
    clone_devtool git@github.com:Khan/arcanist
    clone_devtool git@github.com:Khan/git-workflow
    clone_devtool git@github.com:Khan/our-lovely-cli
}

# khan-dotfiles is also a KA repository...
# thus, use kaclone --repair on current dir to khanify it as well!
kaclone_repair_self() {
    (cd "$DIR" && "$KACLONE_BIN" --repair --quiet)
}

clone_repos() {
    clone_kaclone
    clone_devtools
    if [ "$WEBAPP" = true ]; then
        clone_webapp
    fi
    kaclone_repair_self
}

# Must have cloned the repos first.
install_deps() {
    echo "Installing virtualenv and any global dependencies"

    # Install virtualenv.
    # https://docs.google.com/document/d/1zrmm6byPImfbt7wDyS8PpULwnEckSxna2jhSl38cWt8
    pip2 install -q virtualenv==20.0.23

    # Used by various infra projects for managing python3 environment
    #echo "Installing pipenv"
    #pip3 install -q pipenv

    create_and_activate_virtualenv "$ROOT/.virtualenv/khan27"

    # Need to install yarn first before run `make install_deps`
    # in webapp.
    
    # Load nvm if available
    if [ -f "$HOME"/.nvm/nvm.sh ]
    then
        update "Sourcing nvm"
        . $HOME/.nvm/nvm.sh
    fi
    
    echo "Installing yarn"
    if ! which yarn >/dev/null 2>&1; then
        if [[ -n "${IS_MAC}" ]]; then
            # Mac does not require root - npm is in /usr/local via brew
            npm install -g yarn
        else
            # Linux requires sudo permissions
            npm install -g yarn
        fi
    fi

    # Install all the requirements for khan
    # This also installs npm deps.
    if [ "$WEBAPP" = true ]; then
        echo "Installing webapp dependencies"
        # This checks for gcloud, so we do it after install_and_setup_gcloud.
        ( cd "$REPOS_DIR/webapp" && make install_deps )
    fi
}

install_and_setup_gcloud() {
    "$DEVTOOLS_DIR"/khan-dotfiles/setup-gcloud.sh -r "$ROOT"
}

download_db_dump() {
    if ! [ -f "$REPOS_DIR/webapp/datastore/current.sqlite" ]; then
        echo "Downloading a recent datastore dump"
        ( cd "$REPOS_DIR/webapp" ; make current.sqlite )
    fi
}

create_pg_databases() {
    if [ "$WEBAPP" = true ]; then
        echo "Creating postgres databases"
        ( cd "$REPOS_DIR/webapp" ; make pg_create )
    fi
}

# Make sure we store userinfo so we can pass appropriately when ka-cloning.
update_userinfo() {
    update "Updating your git user info"
    ######
    
    # check if git user.name exists anywhere, if not, set that globally
    set +e
    gitname=$(git config user.name)
    set -e
    if [ -z "$gitname" ]; then
        read -p "Enter your full name (First Last): " name
        git config --global user.name "$name"
        gitname=$(git config user.name)
    fi

    # Set a "sticky" KA email address in the global kaclone.email gitconfig
    # ka-clone will check for this as the default to use when cloning
    # (we still pass --email to ka-clone in this script for redundancy, but
    #  this setting will apply to any future CLI usage of ka-clone.)
    set +e
    gitmail=$(git config kaclone.email)
    set -e
    if [ -z "$gitmail" ]; then
        read -p "Enter your KA email, without the @khanacademy.org ($USER): " emailuser
        emailuser=${emailuser:-$USER}
        defaultemail="$emailuser@khanacademy.org"
        git config --global kaclone.email "$defaultemail"
        gitmail=$(git config kaclone.email)
        echo "Setting kaclone default email to $defaultemail"
    fi
}

# Install webapp's git hooks
install_hooks() {
    if [ "$WEBAPP" = true ]; then
        echo "Installing git hooks"
        ( cd "$REPOS_DIR/webapp" && make hooks )
    fi
}

# Set up .arcrc: we can't update this through the standard process
# because it has secrets embedded in it, but our arcanist fork will
# do the updates for us.
setup_arc() {
    if [ ! -f "$HOME/.arcrc" ]; then
        echo "Time to set up arc to talk to Phabricator!"
        echo "First, go make sure you're logged in and your"
        echo "account is set up (use Google OAuth to create"
        echo "an account, if you haven't).  Click here to start:"
        echo "  -->  https://phabricator.khanacademy.org  <--"
        echo -n "Press enter when you're logged in: "
        read
        # This is added to PATh by dotfiles, but those may not be sourced yet.
        PATH="$DEVTOOLS_DIR/arcanist/khan-bin:$PATH"
        arc install-certificate -- https://phabricator.khanacademy.org
    fi
}


check_dependencies

# the order of these individually doesn't matter but they should come first
update_userinfo
install_dotfiles
# the order for these is (mostly!) important, beware
clone_repos
install_and_setup_gcloud
install_deps        # pre-reqs: clone_repos, install_and_setup_gcloud
install_hooks       # pre-req: clone_repos
setup_arc           # pre-req: clone_repos
download_db_dump    # pre-req: install_deps
create_pg_databases # pre-req: install_deps


echo
echo "---------------------------------------------------------------------"

if [ -n "$warnings" ]; then
    echo "-- WARNINGS:"
    # echo is very inconsistent about whether it supports -e. :-(
    echo "$warnings" | sed 's/\\n/\n/g'
else
    echo "DONE!"
fi

trap - EXIT
