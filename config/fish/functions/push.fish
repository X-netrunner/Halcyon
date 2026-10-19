function push --description 'Sync and push a Halcyon checkout (push halcyon)'
    # The real work is scripts/sync-and-push.sh: it finds every Halcyon checkout on the
    # machine, lists them 1, 2, 3 ..., and syncs + pushes the one you pick.
    set -l script "$HOME/.config/Halcyon/scripts/sync-and-push.sh"
    test -f "$script"; or set script "$HOME/Projects/Halcyon/scripts/sync-and-push.sh"
    test -f "$script"; or set script "$HOME/CustomHyprScripts/sync-and-push.sh"

    if test (count $argv) -eq 0
        echo "usage: push halcyon [number | --list | --dry-run | --all | --yes]"
        return 1
    end

    switch (string lower -- "$argv[1]")
        case halcyon hal
            if not test -f "$script"
                echo "push: can't find sync-and-push.sh (looked in ~/.config/Halcyon/scripts and ~/Projects/Halcyon/scripts)" >&2
                return 1
            end
            bash "$script" $argv[2..-1]
        case '*'
            # bare `push` with no keyword: still help if it is a number/option, else usage
            if string match -qr '^(-|[0-9])' -- "$argv[1]" ; and test -f "$script"
                bash "$script" $argv
            else
                echo "usage: push halcyon [number | --list | --dry-run | --all | --yes]"
                return 1
            end
    end
end
