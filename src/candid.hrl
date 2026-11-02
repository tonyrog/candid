%%% The pixel coordinates candid draws the trace and the plots in. The core
%%% computes every dot in them; a renderer puts the dots there.

-define(TRACE_W,   720).   % trace width, px, right of the labels
-define(GUTTER,    110).   % px of labels at the left of the trace -- the
			   % same width as a row's label, so they line up
-define(ROW_H,      34).   % px per trace row
-define(STEP,        3).   % px per sample
%% The XY plot. SQUARE, because an XY picture is only honest when both axes
%% are the same length -- a circle in a wide box is an ellipse, and you cannot
%% tell which it was. Dark green because the afterglow is a phosphor.
-define(PLOT_W,   240).            % px, square
-define(PLOT_BG,  {16, 20, 16}).
-define(PAD,        4).            % inset, so a full-scale dot is a whole dot
