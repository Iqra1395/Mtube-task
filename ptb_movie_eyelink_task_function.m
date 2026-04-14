function ptb_movie_eyelink_task_function(movieFiles, thumbFiles, useDummyMode, stimScreen, mainScreen, cfg)


if nargin < 3 || isempty(useDummyMode), useDummyMode = 0; end
if ischar(movieFiles) || isstring(movieFiles), movieFiles = {char(movieFiles)}; end
if nargin < 2 || isempty(thumbFiles), thumbFiles = {}; end
if ischar(thumbFiles) || isstring(thumbFiles), thumbFiles = {char(thumbFiles)}; end

% Optional task configuration
% cfg.allowNext : show/enable forward (RIGHT) button (default true)
% cfg.allowPrev : show/enable backward (LEFT) button (default true)
% cfg.prevMode  : what LEFT does: 'history' (default) | 'funOnly' | 'boringOnly' | 'funOrBoring50'
if nargin < 6 || isempty(cfg), cfg = struct(); end
if ~isfield(cfg,'allowNext') || isempty(cfg.allowNext), cfg.allowNext = true; end
if ~isfield(cfg,'allowPrev') || isempty(cfg.allowPrev), cfg.allowPrev = true; end
if ~isfield(cfg,'prevMode')  || isempty(cfg.prevMode),  cfg.prevMode  = 'history'; end
% ---------- STAGING CONTROL ----------
% Stage 1: forward-only for first 50% of iterations (saving fun/boring)
% Stage 2: back-only for some fixed number of iterations
% Stage 3: both buttons for the rest
if ~isfield(cfg,'stage1Frac') || isempty(cfg.stage1Frac), cfg.stage1Frac = 0.50; end
if ~isfield(cfg,'stage2N')    || isempty(cfg.stage2N),    cfg.stage2N    = []; end  % if empty -> auto

SKIP_DWELL_SEC      = 1.2;   % gaze dwell needed on arrow button to trigger next/prev
SKIP_HYST_RESET_SEC = 0.15;   % small grace to avoid accidental reset when gaze jitter
NAV_DELAY_SEC       = 1.20;   % pause after NEXT/PREV trigger before the new movie starts
SHOW_DWELL_BARS     = true;   % show tiny progress bars under arrows
KNOWN_POOL_PROB     = 0.50;   % next selection: prob to sample from known (fun/boring) vs unknown pool
FUN_WATCHCOUNT      = 1;      % fun when watched-to-end count >= this
BORING_SKIPCOUNT    = 1;      % boring when skipped count >= this

try
    AssertOpenGL;
    KbName('UnifyKeyNames');
    escKey   = KbName('ESCAPE');
    leftKey  = KbName('LeftArrow');
    rightKey = KbName('RightArrow');
    
    Screen('Preference','SkipSyncTests', 1); % debugging; set 0 later
    PsychDefaultSetup(2);
    
    screens = Screen('Screens');
    screensNo0 = screens(screens ~= 0);
    
    if nargin < 4 || isempty(stimScreen) || nargin < 5 || isempty(mainScreen)
        if numel(screensNo0) < 2
            warning('Only one non-zero PTB screen found. Both windows will be on the same monitor.');
            stimScreen = screensNo0(1);
            mainScreen = screensNo0(1);
        else
            mainScreen = min(screensNo0);
            stimScreen = max(screensNo0);
        end
    end
    
    fprintf('Using mainScreen=%d stimScreen=%d\n', mainScreen, stimScreen);
    
    % Open windows
    [winStim, stimRect] = PsychImaging('OpenWindow', stimScreen, 0);
    Priority(MaxPriority(winStim));
    HideCursor(winStim);
    stimW = RectWidth(stimRect);
    stimH = RectHeight(stimRect);
    
    gazeWinLocalRect = [100 120 820 620];
    [winGaze, gazeRect] = PsychImaging('OpenWindow', mainScreen, 0, gazeWinLocalRect);
    gazeRectIn = InsetRect(gazeRect, 15, 15);
    
    % Quick debug labels
    Screen('FillRect', winStim, 0);  DrawFormattedText(winStim, 'STIM WINDOW', 'center','center',[255 255 255]); Screen('Flip', winStim);
    Screen('FillRect', winGaze, 50); DrawFormattedText(winGaze, 'GAZE WINDOW', 'center','center',[255 255 255]); Screen('Flip', winGaze);
    WaitSecs(0.4);
    
    
    % EyeLink init (bind defaults to STIM)
    el = EyelinkInitDefaults(winStim);
    el.backgroundcolour = 0;
    el.foregroundcolour = 255;
    el.msgfontcolour    = 255;
    el.imgtitlecolour   = 255;
    EyelinkUpdateDefaults(el);
    
    if ~EyelinkInit(useDummyMode)
        error('EyelinkInit failed. Is the tracker connected?');
    end
    
    edfFile = 'MOVNAV.edf';
    if Eyelink('Openfile', edfFile) ~= 0
        error('Cannot create EDF file on Host PC.');
    end
    
    Eyelink('Command', 'file_event_filter = LEFT,RIGHT,FIXATION,SACCADE,BLINK,MESSAGE,BUTTON');
    Eyelink('Command', 'file_sample_data  = LEFT,RIGHT,GAZE,AREA,GAZERES,STATUS,HTARGET');
    Eyelink('Command', 'link_event_filter = LEFT,RIGHT,FIXATION,SACCADE,BLINK,BUTTON');
    Eyelink('Command', 'link_sample_data  = LEFT,RIGHT,GAZE,AREA,GAZERES,STATUS,HTARGET');
    
    Eyelink('Message', 'START_MOVIE_TASK_NAV');
    
    EyelinkDoTrackerSetup(el);
    
    Eyelink('StartRecording');
    WaitSecs(0.05);
    Eyelink('Message','RECORDING_START');
    
    
    % Build video DB
    nV = numel(movieFiles);
    if nV < 1, error('movieFiles is empty'); end
    
    vid = struct();
    for i = 1:nV
        vid(i).file = movieFiles{i};
        if i <= numel(thumbFiles)
            vid(i).thumbFile = thumbFiles{i};
        else
            vid(i).thumbFile = '';
        end
        vid(i).thumbTex = [];
        vid(i).watchFullCount = 0;
        vid(i).skipCount      = 0;
        vid(i).category       = "unknown"; % "unknown" | "boring" | "fun"
    end
    
    % Preload thumbnails
    for i = 1:nV
        if ~isempty(vid(i).thumbFile) && isfile(vid(i).thumbFile)
            img = imread(vid(i).thumbFile);
            vid(i).thumbTex = Screen('MakeTexture', winStim, img);
        end
    end
    
    
    % Logs (optional: per-frame gaze for the WHOLE session)
    
    gazeLog = nan(500000,6); % [tFlipStim, eyeTime, gx, gy, pa, movieIdx]
    nLog = 0;
    
    lastValid = false; lastX = NaN; lastY = NaN;
    rDot = 8;
    
    
    % Navigation state
    history = [];   % stack of previously played indices (excluding current)
    currentIdx = 1; % start at first
    rng('shuffle');
    
    Eyelink('Message', sprintf('SESSION_START_NVIDEOS_%d', nV));
    
    
    % ---------- Determine stage lengths ----------
    Ntotal = numel(movieFiles);
    
    stage1N = max(1, round(cfg.stage1Frac * Ntotal));   % first 50% time
    if isempty(cfg.stage2N)
        stage2N = max(1, round(0.25 * Ntotal));         % default: 25% time (you can change in Maintask)
    else
        stage2N = cfg.stage2N;
    end
    
    navStep = 0;  % counts how many videos have been played/left
    
    
    % ------------------ MAIN LOOP ----------------------------
    keepRunning = true;
    while keepRunning
        
        % Play current movie (with arrow buttons)
        % ---------- Dynamic stage switching ----------
        navStep = navStep + 1;
        
        if navStep <= stage1N
            % Stage 1: FORWARD ONLY (collect/save fun/boring)
            allowPrev = false;
            allowNext = true;
            Eyelink('Message', sprintf('PHASE_1_FORWARD_ONLY_STEP_%d', navStep));
            
        elseif navStep <= (stage1N + stage2N)
            % Stage 2: BACK ONLY (FUN-only for this task)
            allowPrev = true;
            allowNext = false;
            Eyelink('Message', sprintf('PHASE_2_BACK_ONLY_STEP_%d', navStep));
            
        else
            % Stage 3: BOTH buttons
            allowPrev = true;
            allowNext = true;
            Eyelink('Message', sprintf('PHASE_3_BOTH_STEP_%d', navStep));
        end
        
        [endReason, didFinish, gazeLog, nLog] = playMovieWithNav(currentIdx, gazeLog, nLog, allowPrev, allowNext);
        if strcmp(endReason,'esc')
            keepRunning = false;
            break;
        end
        
        % Update categorization for the movie we just left
        if didFinish
            vid(currentIdx).watchFullCount = vid(currentIdx).watchFullCount + 1;
            Eyelink('Message', sprintf('WATCHFULL_IDX_%d_COUNT_%d', currentIdx, vid(currentIdx).watchFullCount));
        else
            vid(currentIdx).skipCount = vid(currentIdx).skipCount + 1;
            Eyelink('Message', sprintf('SKIP_IDX_%d_COUNT_%d', currentIdx, vid(currentIdx).skipCount));
        end
        vid = updateCategories(vid);
        
        % Decide next index
        if strcmp(endReason,'prev')
            % LEFT button behavior depends on cfg.prevMode
            switch lower(cfg.prevMode)
                case 'history'
                    if ~isempty(history)
                        nextIdx = history(end);
                        history(end) = [];
                        Eyelink('Message', sprintf('NAV_PREV_TO_%d', nextIdx));
                        transitionSplash('PREVIOUS VIDEO', [0 120 255]);
                        currentIdx = nextIdx;
                    else
                        Eyelink('Message', 'NAV_PREV_EMPTY_HISTORY');
                        % stay on current (replay)
                    end
                    
                case 'funonly'
                    nextIdx = pickFromCategory(currentIdx, vid, "fun");
                    Eyelink('Message', sprintf('NAV_PREV_FUN_TO_%d', nextIdx));
                    transitionSplash('FUN VIDEO', [0 120 255]);
                    currentIdx = nextIdx;
                    
                case 'boringonly'
                    nextIdx = pickFromCategory(currentIdx, vid, "boring");
                    Eyelink('Message', sprintf('NAV_PREV_BORING_TO_%d', nextIdx));
                    transitionSplash('BORING VIDEO', [0 120 255]);
                    currentIdx = nextIdx;
                    
                case {'funorboring50','funboring50','50'}
                    nextIdx = pickFromKnown50(currentIdx, vid);
                    Eyelink('Message', sprintf('NAV_PREV_KNOWN50_TO_%d', nextIdx));
                    transitionSplash('KNOWN VIDEO', [0 120 255]);
                    currentIdx = nextIdx;
                    
                otherwise
                    % fallback to history
                    if ~isempty(history)
                        nextIdx = history(end);
                        history(end) = [];
                        Eyelink('Message', sprintf('NAV_PREV_TO_%d', nextIdx));
                        transitionSplash('PREVIOUS VIDEO', [0 120 255]);
                        currentIdx = nextIdx;
                    else
                        Eyelink('Message', 'NAV_PREV_EMPTY_HISTORY');
                    end
            end
            
        elseif strcmp(endReason,'next')
            history = [history, currentIdx]; %#ok<AGROW>
            nextIdx = pickNextUnknownIndex(currentIdx, vid);
            Eyelink('Message', sprintf('NAV_NEXT_TO_%d', nextIdx));
            transitionSplash('NEXT VIDEO', [0 180 0]);
            currentIdx = nextIdx;
            
        elseif strcmp(endReason,'finished')
            % After full watch, optionally show 3-thumbnails selection.
            [canShow, candIdx] = pickThreeCandidates(currentIdx, vid);
            if canShow
                chosenIdx = chooseByThumbDwell(candIdx, vid);
                history = [history, currentIdx];
                Eyelink('Message', sprintf('ENDSCREEN_CHOSEN_%d', chosenIdx));
                transitionSplash('STARTING VIDEO', [0 0 0]);
                currentIdx = chosenIdx;
            else
                % fallback: same logic as NEXT
                history = [history, currentIdx];
                nextIdx = pickNextUnknownIndex(currentIdx, vid);
                Eyelink('Message', sprintf('ENDSCREEN_FALLBACK_NEXT_%d', nextIdx));
                transitionSplash('NEXT VIDEO', [0 180 0]);
                currentIdx = nextIdx;
            end
        else
            % safety fallback
            history = [history, currentIdx];
            currentIdx = pickNextIndex(currentIdx, vid, KNOWN_POOL_PROB);
        end
    end
    
    
    % Stop recording / save
    Eyelink('StopRecording');
    Eyelink('Message','RECORDING_STOP');
    Eyelink('CloseFile');
    
    localEdf = fullfile(pwd, edfFile);
    try
        Eyelink('ReceiveFile', edfFile, localEdf, 1);
        fprintf('EDF saved to: %s\n', localEdf);
    catch
        warning('Could not receive EDF automatically. Copy it from Host PC if needed.');
    end
    
    Eyelink('Shutdown');
    
    gazeLog = gazeLog(1:nLog,:);
    save('movie_nav_session.mat', 'gazeLog', 'movieFiles', 'thumbFiles', 'vid', 'history', 'mainScreen', 'stimScreen');
    
    Priority(0);
    ShowCursor;
    
    % Close textures
    for i = 1:nV
        if ~isempty(vid(i).thumbTex)
            Screen('Close', vid(i).thumbTex);
        end
    end
    
    sca;
    fprintf('Done. Logged gaze samples: %d\n', nLog);
    
catch ME
    try Screen('CloseAll'); catch, end
    try Eyelink('Shutdown'); catch, end
    Priority(0); ShowCursor;
    rethrow(ME);
end

% ===================== NESTED HELPERS


    function transitionSplash(labelText, colorRGB)
        % Visible pause between videos so subject can tell a new video is starting.
        % colorRGB: optional background tint. Default: black.
        if nargin < 2 || isempty(colorRGB)
            colorRGB = [0 0 0];
        end
        Screen('FillRect', winStim, colorRGB);
        DrawFormattedText(winStim, labelText, 'center', 'center', [255 255 255]);
        Screen('Flip', winStim);
        WaitSecs(NAV_DELAY_SEC);
    end


    function vid = updateCategories(vid)
        for ii = 1:numel(vid)
            if vid(ii).watchFullCount >= FUN_WATCHCOUNT
                vid(ii).category = "fun";
            elseif vid(ii).skipCount >= BORING_SKIPCOUNT
                vid(ii).category = "boring";
            else
                vid(ii).category = "unknown";
            end
        end
    end

    function nextIdx = pickNextUnknownIndex(currIdx, vid)
        % NEXT (skip) chooses ONLY from UNKNOWN videos.
        % If no unknown remain (excluding current), fall back to any non-current.
        idxAll = setdiff(1:numel(vid), currIdx);
        if isempty(idxAll), nextIdx = currIdx; return; end
        
        unknownMask = vidCatMask(vid,"unknown");
        pool = idxAll(unknownMask(idxAll));
        
        if isempty(pool)
            pool = idxAll; % fallback if no unknown left
        end
        
        nextIdx = pool(randi(numel(pool)));
    end


    function nextIdx = pickFromCategory(currIdx, vid, cat)
        % Pick NEXT index from a specific category only (excluding current).
        idxAll = setdiff(1:numel(vid), currIdx);
        if isempty(idxAll), nextIdx = currIdx; return; end
        
        m = vidCatMask(vid, cat);
        pool = idxAll(m(idxAll));
        if isempty(pool)
            % If no videos in that category exist yet, stay on current.
            nextIdx = currIdx;
            return;
        end
        nextIdx = pool(randi(numel(pool)));
    end

    function nextIdx = pickFromKnown50(currIdx, vid)
        % Pick from fun or boring with 50/50 chance; fall back if one is empty.
        idxAll = setdiff(1:numel(vid), currIdx);
        if isempty(idxAll), nextIdx = currIdx; return; end
        
        mFun = vidCatMask(vid,'fun');
        mBor = vidCatMask(vid,'boring');
        funPool    = idxAll(mFun(idxAll));
        boringPool = idxAll(mBor(idxAll));
        
        if rand < 0.5
            pool = funPool;
            if isempty(pool), pool = boringPool; end
        else
            pool = boringPool;
            if isempty(pool), pool = funPool; end
        end
        
        if isempty(pool)
            nextIdx = currIdx;
        else
            nextIdx = pool(randi(numel(pool)));
        end
    end

    function nextIdx = pickNextIndex(currIdx, vid, knownProb)
        % Pools excluding current
        idxAll = setdiff(1:numel(vid), currIdx);
        if isempty(idxAll), nextIdx = currIdx; return; end
        
        isKnown = (vidCatMask(vid,"fun") | vidCatMask(vid,"boring"));
        knownPool = idxAll(isKnown(idxAll));
        unknownPool = idxAll(~isKnown(idxAll));
        
        if rand < knownProb
            pool = knownPool;
            if isempty(pool), pool = unknownPool; end
            if isempty(pool), pool = idxAll; end
        else
            pool = unknownPool;
            if isempty(pool), pool = knownPool; end
            if isempty(pool), pool = idxAll; end
        end
        
        nextIdx = pool(randi(numel(pool)));
    end

    function mask = vidCatMask(vid, cat)
        mask = false(1,numel(vid));
        for ii=1:numel(vid)
            mask(ii) = strcmp(vid(ii).category, cat);
        end
    end

    function [ok, candIdx] = pickThreeCandidates(currIdx, vid)
        % only candidates that have thumbnails loaded
        hasThumb = false(1,numel(vid));
        for ii=1:numel(vid)
            hasThumb(ii) = ~isempty(vid(ii).thumbTex);
        end
        
        pool = find(hasThumb);
        pool = setdiff(pool, currIdx);
        
        ok = numel(pool) >= 3;
        candIdx = [];
        if ok
            rp = pool(randperm(numel(pool),3));
            candIdx = rp(:)';
        end
    end

    function chosenIdx = chooseByThumbDwell(candIdx, vid)
        % Endscreen with 3 thumbnails; dwell selects.
        margin = round(0.10 * stimW);
        gap    = round(0.05 * stimW);
        thumbW = floor((stimW - 2*margin - 2*gap) / 3);
        thumbH = floor(thumbW * 9/16);
        y1 = round(stimH * 0.35);
        y2 = y1 + thumbH;
        
        thumbRect = zeros(3,4);
        for k = 1:3
            x1 = margin + (k-1)*(thumbW + gap);
            x2 = x1 + thumbW;
            thumbRect(k,:) = [x1 y1 x2 y2];
        end
        
        dwell = zeros(1,3);
        dwellThresh = 0.80;
        timeoutSec  = 10.0;
        
        selectedK = 0;
        tPrev = GetSecs;
        tStartChoose = tPrev;
        
        Eyelink('Message','ENDSCREEN_START');
        
        while selectedK == 0
            tNow = GetSecs;
            dt = tNow - tPrev;
            tPrev = tNow;
            
            [down,~,keyCode] = KbCheck;
            if down && keyCode(escKey)
                Eyelink('Message','ENDSCREEN_ABORT_ESC');
                selectedK = 1; % default
                break;
            end
            
            haveGaze = false; gxS = NaN; gyS = NaN;
            if Eyelink('NewFloatSampleAvailable') > 0
                fs = Eyelink('NewestFloatSample');
                gxS = fs.gx(1); gyS = fs.gy(1);
                if gxS == el.MISSING_DATA || gyS == el.MISSING_DATA
                    gxS = fs.gx(2); gyS = fs.gy(2);
                end
                haveGaze = isfinite(gxS) && isfinite(gyS) && gxS~=el.MISSING_DATA && gyS~=el.MISSING_DATA;
            end
            
            lookedK = 0;
            if haveGaze
                gxS = min(max(gxS,0), stimW-1);
                gyS = min(max(gyS,0), stimH-1);
                for k = 1:3
                    if IsInRect(gxS, gyS, thumbRect(k,:))
                        lookedK = k;
                        dwell(k) = dwell(k) + dt;
                        break;
                    end
                end
            end
            
            Screen('FillRect', winStim, 0);
            DrawFormattedText(winStim, 'Look at a thumbnail to select next video', 'center', round(stimH*0.20), [255 255 255]);
            
            for k = 1:3
                Screen('DrawTexture', winStim, vid(candIdx(k)).thumbTex, [], thumbRect(k,:));
                if k == lookedK
                    Screen('FrameRect', winStim, [255 0 0], thumbRect(k,:), 8);
                else
                    Screen('FrameRect', winStim, [200 200 200], thumbRect(k,:), 2);
                end
                
                bar = thumbRect(k,:);
                bar(2) = bar(4) + 12;
                bar(4) = bar(2) + 12;
                frac = min(dwell(k)/dwellThresh, 1);
                barFill = bar;
                barFill(3) = barFill(1) + round(frac * RectWidth(bar));
                Screen('FrameRect', winStim, [200 200 200], bar, 1);
                Screen('FillRect',  winStim, [200 200 200], barFill);
            end
            
            Screen('Flip', winStim);
            
            [mx, kbest] = max(dwell);
            if mx >= dwellThresh
                selectedK = kbest;
                Eyelink('Message', sprintf('ENDSCREEN_SELECT_SLOT_%d', selectedK));
            end
            
            if (tNow - tStartChoose) > timeoutSec
                selectedK = kbest;
                Eyelink('Message', sprintf('ENDSCREEN_TIMEOUT_SELECT_SLOT_%d', selectedK));
            end
        end
        
        chosenIdx = candIdx(selectedK);
        Eyelink('Message','ENDSCREEN_END');
    end

    function [endReason, didFinish, gazeLog, nLog] = playMovieWithNav(movieIdx, gazeLog, nLog, allowPrev, allowNext)        % Returns:
        %   endReason: 'finished' | 'next' | 'prev' | 'esc'
        %   didFinish: true if movie reached end (tex<=0), false if skipped or esc
        
        movieFile = vid(movieIdx).file;
        if ~isfile(movieFile)
            Eyelink('Message', sprintf('MISSING_MOVIE_%d', movieIdx));
            warning('Missing movie file: %s', movieFile);
            endReason = 'next';
            didFinish = false;
            return;
        end
        
        [moviePtr, ~, ~, mw, mh] = Screen('OpenMovie', winStim, movieFile, 0, 1, 2);
        Screen('PlayMovie', moviePtr, 1, 0, 1.0);
        
        % --- Draw movie in a CENTER "video frame" that leaves margins for arrows ---
        btnW = round(0.10 * stimW);
        btnH = round(0.60 * stimH);
        pad  = round(0.02 * stimW);   % padding between video and buttons/margins
        
        % Reserve left+right margins for buttons (outside the video frame)
        leftMargin  = btnW + 2*pad;
        rightMargin = btnW + 2*pad;
        
        % Reserve a little space at bottom if dwell bars are on
        if SHOW_DWELL_BARS
            bottomMargin = 40;
        else
            bottomMargin = 10;
        end
        topMargin = 10;
        
        videoFrame = [leftMargin, topMargin, stimW-rightMargin, stimH-bottomMargin];
        
        innerW = RectWidth(videoFrame);
        innerH = RectHeight(videoFrame);
        
        scale = min(innerW/mw, innerH/mh);
        dstStim = CenterRectOnPoint(ScaleRect([0 0 mw mh], scale, scale), ...
            (videoFrame(1)+videoFrame(3))/2, (videoFrame(2)+videoFrame(4))/2);
        
        Eyelink('Message', sprintf('MOVIE_START_%d', movieIdx));
        
        % Arrow button regions (placed OUTSIDE the videoFrame but still on-screen)
        btnYc = (videoFrame(2) + videoFrame(4)) / 2;
        
        % Left button centered in the left margin; Right in the right margin
        leftX  = (videoFrame(1) / 2);
        rightX = (videoFrame(3) + stimW) / 2;
        
        leftRect  = CenterRectOnPoint([0 0 btnW btnH], leftX,  btnYc);
        rightRect = CenterRectOnPoint([0 0 btnW btnH], rightX, btnYc);
        
        dwellL = 0; dwellR = 0;
        lastInL = 0; lastInR = 0;
        tPrev = GetSecs;
        
        didFinish = false;
        endReason = 'finished';
        
        while true
            tNow = GetSecs;
            dt = tNow - tPrev;
            tPrev = tNow;
            
            tex = Screen('GetMovieImage', winStim, moviePtr, 1);
            if tex <= 0
                didFinish = true;
                endReason = 'finished';
                break;
            end
            
            % Read gaze once/frame (robust): always grab newest sample
            haveSample = false; gx = NaN; gy = NaN; pa = NaN; eyeTime = NaN;
            fs = Eyelink('NewestFloatSample');
            if ~isempty(fs)
                gx = fs.gx(1); gy = fs.gy(1); pa = fs.pa(1);
                if gx == el.MISSING_DATA || gy == el.MISSING_DATA
                    gx = fs.gx(2); gy = fs.gy(2); pa = fs.pa(2);
                end
                eyeTime = fs.time;
                haveSample = isfinite(gx) && isfinite(gy) && gx~=el.MISSING_DATA && gy~=el.MISSING_DATA;
            end
            
            % Handle arrow dwell logic (gaze)
            inL = false; inR = false;
            if haveSample
                gxC = min(max(gx,0), stimW-1);
                gyC = min(max(gy,0), stimH-1);
                inL = IsInRect(gxC, gyC, leftRect);
                inR = IsInRect(gxC, gyC, rightRect);
                
                % If a button is disabled, force its dwell inactive
                if ~allowPrev
                    inL = false;
                    dwellL = 0;
                end
                if ~allowNext
                    inR = false;
                    dwellR = 0;
                end
                
                if inL
                    dwellL = dwellL + dt;
                    lastInL = tNow;
                elseif (tNow - lastInL) > SKIP_HYST_RESET_SEC
                    dwellL = 0;
                end
                
                if inR
                    dwellR = dwellR + dt;
                    lastInR = tNow;
                elseif (tNow - lastInR) > SKIP_HYST_RESET_SEC
                    dwellR = 0;
                end
            else
                % no gaze: slowly decay
                dwellL = max(0, dwellL - dt);
                dwellR = max(0, dwellR - dt);
            end
            
            % Keyboard shortcuts (debug)
            [down,~,keyCode] = KbCheck;
            if down && keyCode(escKey)
                Eyelink('Message', sprintf('ABORT_ESC_AT_MOVIE_%d', movieIdx));
                endReason = 'esc';
                didFinish = false;
                break;
            elseif down && keyCode(leftKey)
                Eyelink('Message', sprintf('KEY_PREV_AT_MOVIE_%d', movieIdx));
                endReason = 'prev';
                didFinish = false;
                break;
            elseif down && keyCode(rightKey)
                Eyelink('Message', sprintf('KEY_NEXT_AT_MOVIE_%d', movieIdx));
                endReason = 'next';
                didFinish = false;
                break;
            end
            
            % Trigger by dwell
            if allowPrev && dwellL >= SKIP_DWELL_SEC
                Eyelink('Message', sprintf('GAZE_PREV_AT_MOVIE_%d', movieIdx));
                endReason = 'prev';
                didFinish = false;
                break;
            end
            if allowNext && dwellR >= SKIP_DWELL_SEC
                Eyelink('Message', sprintf('GAZE_NEXT_AT_MOVIE_%d', movieIdx));
                endReason = 'next';
                didFinish = false;
                break;
            end
            
            % Draw movie + arrows
            Screen('FillRect', winStim, 0);
            Screen('DrawTexture', winStim, tex, [], dstStim);
            Screen('Close', tex);
            
            if allowPrev
                drawArrowButton(leftRect,  'left',  inL, dwellL/SKIP_DWELL_SEC);
            end
            if allowNext
                drawArrowButton(rightRect, 'right', inR, dwellR/SKIP_DWELL_SEC);
            end
            % Debug dwell readout (helps confirm gaze is being detected on buttons)
            dbg = sprintf('dwellL=%.2f / %.2f   dwellR=%.2f / %.2f', dwellL, SKIP_DWELL_SEC, dwellR, SKIP_DWELL_SEC);
            DrawFormattedText(winStim, dbg, 20, stimH-30, [200 200 200]);
            
            % small status text (optional)
            status = sprintf('Video %d/%d   (fun=%d  boring=%d  unknown=%d)', ...
                movieIdx, nV, sum(vidCatMask(vid,"fun")), sum(vidCatMask(vid,"boring")), sum(vidCatMask(vid,"unknown")));
            DrawFormattedText(winStim, status, 20, 20, [200 200 200]);
            
            tFlipStim = Screen('Flip', winStim);
            
            % Draw gaze window
            Screen('FillRect', winGaze, [20 20 20]);
            Screen('FrameRect', winGaze, [200 200 200], gazeRect, 2);
            DrawFormattedText(winGaze, 'Realtime gaze (STIM coords)', gazeRectIn(1), gazeRectIn(2)-25, [200 200 200]);
            
            if haveSample
                gxC = min(max(gx,0), stimW-1);
                gyC = min(max(gy,0), stimH-1);
                nx = gxC / stimW; ny = gyC / stimH;
                xDot = gazeRectIn(1) + nx * RectWidth(gazeRectIn);
                yDot = gazeRectIn(2) + ny * RectHeight(gazeRectIn);
                lastX = xDot; lastY = yDot; lastValid = true;
                Screen('FillOval', winGaze, [0 255 0], [xDot-rDot yDot-rDot xDot+rDot yDot+rDot]);
            else
                if lastValid
                    Screen('FillOval', winGaze, [255 255 0], [lastX-rDot lastY-rDot lastX+rDot lastY+rDot]);
                else
                    [cx,cy] = RectCenter(gazeRectIn);
                    Screen('FillOval', winGaze, [255 0 0], [cx-rDot cy-rDot cx+rDot cy+rDot]);
                end
            end
            Screen('Flip', winGaze);
            
            % Log
            if ~isnan(eyeTime)
                nLog = nLog + 1;
                if nLog > size(gazeLog,1)
                    gazeLog(end+200000,:) = nan;
                end
                if haveSample
                    gxStore = min(max(gx,0), stimW-1);
                    gyStore = min(max(gy,0), stimH-1);
                else
                    gxStore = gx; gyStore = gy;
                end
                gazeLog(nLog,:) = [tFlipStim, eyeTime, gxStore, gyStore, pa, movieIdx];
            end
        end
        
        Screen('PlayMovie', moviePtr, 0);
        Screen('CloseMovie', moviePtr);
        Eyelink('Message', sprintf('MOVIE_END_%d_REASON_%s', movieIdx, upper(endReason)));
    end

    function drawArrowButton(rect, dir, isHot, frac)
        % Colored arrow buttons:
        % LEFT  = Blue  (turns RED when gaze is on it)
        % RIGHT = Green (turns RED when gaze is on it)
        frac = min(max(frac,0),1);
        
        if strcmp(dir,'left')
            baseColor  = [0 120 255];   % blue
        else
            baseColor  = [0 180 0];     % green
        end
        
        gazeColor = [220 0 0];          % RED fill whenever gaze is on button
        gazeEdge  = [255 80 80];        % bright red border during gaze
        
        if isHot
            bg   = gazeColor;   % fill turns red immediately on gaze
            edge = gazeEdge;
            lw   = 8;
        else
            bg   = baseColor;
            edge = baseColor;
            lw   = 2;
        end
        
        Screen('FillRect', winStim, bg, rect);
        Screen('FrameRect', winStim, edge, rect, lw);
        
        % Arrow triangle (white)
        x1=rect(1); y1=rect(2); x2=rect(3); y2=rect(4);
        cy=(y1+y2)/2;
        
        if strcmp(dir,'left')
            xTip   = x1 + 0.30*(x2-x1);
            xBack  = x1 + 0.70*(x2-x1);
        else
            xTip   = x1 + 0.70*(x2-x1);
            xBack  = x1 + 0.30*(x2-x1);
        end
        
        pts = [xBack xTip xBack; ...
            y1+0.20*(y2-y1) cy y1+0.80*(y2-y1)];
        Screen('FillPoly', winStim, [255 255 255], pts', 1);
        
        if SHOW_DWELL_BARS
            bar = rect;
            bar(2) = rect(4) + 8;
            bar(4) = bar(2) + 10;
            
            barColor = edge; % matches button colour: red during gaze, base otherwise
            Screen('FrameRect', winStim, barColor, bar, 2);
            
            fill = bar;
            fill(3) = fill(1) + round(frac * RectWidth(bar));
            Screen('FillRect', winStim, barColor, fill);
        end
    end

end