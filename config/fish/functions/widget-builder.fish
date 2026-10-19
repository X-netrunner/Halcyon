function widget-builder --description 'Open the widget builder (layout and look of each desktop widget; "widget-builder lock" = the lock screen)'
    if test "$argv[1]" = lock
        halcyon lock-widget-builder
    else
        halcyon widget-builder
    end
end
