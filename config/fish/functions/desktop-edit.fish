function desktop-edit --description 'Drag, resize and add your widgets right on the desktop ("desktop-edit lock" = on the lock screen)'
    if test "$argv[1]" = lock
        halcyon lock-desktop-edit
    else
        halcyon desktop-edit
    end
end
