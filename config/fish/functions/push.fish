function push --description 'Sync and push Halcyon, ai-firewall or LUNA-AI (push halcyon | firewall | luna | all)'
    # The real work is scripts/sync-and-push.sh: it finds every Halcyon checkout on the
    # machine, lists them 1, 2, 3 ..., and syncs + pushes the one you pick.
    # ai-firewall and LUNA-AI are found by their GitHub remote (wherever they are checked out)
    # and go through the same script with --repo.
    set -l script "$HOME/.config/Halcyon/scripts/sync-and-push.sh"
    test -f "$script"; or set script "$HOME/Projects/Halcyon/scripts/sync-and-push.sh"
    test -f "$script"; or set script "$HOME/CustomHyprScripts/sync-and-push.sh"
    set -l usage "usage: push halcyon|firewall|luna|all [number | --list | --dry-run | --yes | -m \"message\"]"

    if test (count $argv) -eq 0
        echo $usage
        return 1
    end
    if not test -f "$script"
        echo "push: can't find sync-and-push.sh (looked in ~/.config/Halcyon/scripts and ~/Projects/Halcyon/scripts)" >&2
        return 1
    end

    switch (string lower -- "$argv[1]")
        case halcyon hal
            bash "$script" $argv[2..-1]
        case firewall ai-firewall fw
            __push_repo X-netrunner/ai-firewall $argv[2..-1]
        case luna luna-ai
            __push_repo X-netrunner/LUNA-AI $argv[2..-1]
        case all
            # one after the other; a failure in one does not stop the next
            set -l failed
            bash "$script" $argv[2..-1]; or set -a failed halcyon
            __push_repo X-netrunner/ai-firewall $argv[2..-1]; or set -a failed ai-firewall
            __push_repo X-netrunner/LUNA-AI $argv[2..-1]; or set -a failed LUNA-AI
            if test (count $failed) -gt 0
                echo "push: not pushed: $failed" >&2
                return 1
            end
        case '*'
            # bare `push` with no keyword: still help if it is a number/option, else usage
            if string match -qr '^(-|[0-9])' -- "$argv[1]"
                bash "$script" $argv
            else
                echo $usage
                return 1
            end
    end
end

# The checkout whose origin is github.com/<slug> (first one found), then sync-and-push.sh --repo
function __push_repo --argument-names slug
    set -l script "$HOME/.config/Halcyon/scripts/sync-and-push.sh"
    test -f "$script"; or set script "$HOME/Projects/Halcyon/scripts/sync-and-push.sh"
    set -l name (string split -r -m1 / -- $slug)[-1]
    for dir in $HOME/Projects/* $HOME/Downloads/* $HOME/*
        test -d "$dir/.git"; or continue
        set -l url (git -C "$dir" remote get-url origin 2>/dev/null)
        if string match -qir -- "github\.com[:/]$slug(\.git)?\$" "$url"
            echo "== $name: $dir"
            bash "$script" --repo "$dir" $argv[2..-1]
            return $status
        end
    end
    echo "push: no checkout of $slug found in ~/Projects, ~/Downloads or ~" >&2
    return 1
end
