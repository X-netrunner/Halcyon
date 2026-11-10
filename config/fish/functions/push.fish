function push --description 'Sync and push Halcyon, ai-firewall, ai-antivirus or LUNA-AI (push halcyon | firewall | antivirus | luna | all)'
    # The real work is scripts/sync-and-push.sh: it finds every Halcyon checkout on the
    # machine, lists them 1, 2, 3 ..., and syncs + pushes the one you pick.
    # ai-firewall, ai-antivirus and LUNA-AI are found by their GitHub remote (or matching unversioned folder)
    # and go through the same script with --repo.
    set -l script "$HOME/.config/Halcyon/scripts/sync-and-push.sh"
    test -f "$script"; or set script "$HOME/Projects/Halcyon/scripts/sync-and-push.sh"
    test -f "$script"; or set script "$HOME/CustomHyprScripts/sync-and-push.sh"
    set -l usage "usage: push halcyon|firewall|antivirus|luna|all [number | --list | --dry-run | --yes | --force | -m \"message\"]"

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
        case antivirus ai-antivirus av
            __push_repo X-netrunner/ai-antivirus $argv[2..-1]
        case luna luna-ai
            __push_repo X-netrunner/LUNA-AI $argv[2..-1]
        case all
            # one after the other; a failure in one does not stop the next
            set -l failed
            bash "$script" $argv[2..-1]; or set -a failed halcyon
            __push_repo X-netrunner/ai-firewall $argv[2..-1]; or set -a failed ai-firewall
            __push_repo X-netrunner/ai-antivirus $argv[2..-1]; or set -a failed ai-antivirus
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

function __matches_repo --argument-names dir slug lower_name
    test -d "$dir"; or return 1

    # 1. If it has .git, check origin remote
    if test -d "$dir/.git"
        set -l url (git -C "$dir" remote get-url origin 2>/dev/null)
        if string match -qir -- "github\.com[:/]$slug(\.git)?\$" "$url"
            return 0
        end
        return 1
    end

    # 2. If it is unversioned (no .git), check folder name and signature files
    set -l b (string lower -- (basename "$dir"))
    switch "$lower_name"
        case luna-ai luna
            if test "$b" = "luna-ai" -o "$b" = "luna"; or string match -q "*luna*" "$b"
                test -f "$dir/Cargo.toml" -o -f "$dir/luna.toml.example" -o -d "$dir/src"; and return 0
            end
            test -f "$dir/luna.toml.example" -o -d "$dir/whapp"; and return 0
        case ai-firewall firewall
            if test "$b" = "ai-firewall" -o "$b" = "firewall"; or string match -q "*firewall*" "$b"
                test -f "$dir/Cargo.toml" -o -d "$dir/ai-firewall-ebpf"; and return 0
            end
            test -d "$dir/ai-firewall-ebpf"; and return 0
        case ai-antivirus antivirus
            if test "$b" = "ai-antivirus" -o "$b" = "antivirus"; or string match -q "*antivirus*" "$b"
                test -f "$dir/Cargo.toml" -o -d "$dir/rules"; and return 0
            end
            test -d "$dir/rules" -a -d "$dir/xtask"; and return 0
        case '*'
            if test "$b" = "$lower_name"
                return 0
            end
    end
    return 1
end

# The checkout whose origin is github.com/<slug> or matching folder, then sync-and-push.sh --repo
function __push_repo --argument-names slug
    set -l script "$HOME/.config/Halcyon/scripts/sync-and-push.sh"
    test -f "$script"; or set script "$HOME/Projects/Halcyon/scripts/sync-and-push.sh"
    set -l name (string split -r -m1 / -- $slug)[-1]
    set -l lower_name (string lower -- "$name")

    # Check if current directory is a checkout or unversioned folder of this project
    if __matches_repo "$PWD" "$slug" "$lower_name"
        echo "== $name: $PWD"
        bash "$script" --repo "$PWD" --slug "$slug" $argv[2..-1]
        return $status
    end

    # Search in priority order: ~/Projects, ~/Downloads, ~, then ~/.local/src
    for dir in $HOME/Projects/* $HOME/Downloads/* $HOME/* $HOME/.local/src/*
        test -d "$dir"; or continue
        if __matches_repo "$dir" "$slug" "$lower_name"
            echo "== $name: $dir"
            bash "$script" --repo "$dir" --slug "$slug" $argv[2..-1]
            return $status
        end
    end

    echo "push: no checkout of $slug found in ~/Projects, ~/Downloads, ~/.local/src or ~" >&2
    return 1
end
