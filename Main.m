
baseDir = 'C:\Monkeytube directory\';

movieFiles = {
    fullfile(baseDir, 'monkey_video.mp4')
    fullfile(baseDir, 'monkeyvideo2.mp4')
    fullfile(baseDir, 'monkeyvideo3.mp4')
    fullfile(baseDir, 'monkeyvideo4.mp4')
    fullfile(baseDir, 'monkeyvideo5.mp4')
    fullfile(baseDir, 'monkeyvideo6.mp4')
    fullfile(baseDir, 'monkeyvideo7.mp4')
    fullfile(baseDir, 'monkeyvideo8.mp4')
    fullfile(baseDir, 'monkeyvideo9.mp4')
    fullfile(baseDir, 'monkeyvideo10.mp4')
    fullfile(baseDir, 'monkeyvideo11.mp4')
    fullfile(baseDir, 'monkeyvideo12.mp4')
    
};


thumbFiles = {
    fullfile(baseDir, 'monkey_video.jpg')
    fullfile(baseDir, 'monkeyvideo2.jpg')
    fullfile(baseDir, 'monkeyvideo3.jpg')
    fullfile(baseDir, 'monkeyvideo4.jpg')
    fullfile(baseDir, 'monkeyvideo5.jpg')
    fullfile(baseDir, 'monkeyvideo6.jpg')
    fullfile(baseDir, 'monkeyvideo7.jpg')
    fullfile(baseDir, 'monkeyvideo8.jpg')
    fullfile(baseDir, 'monkeyvideo9.jpg')
    fullfile(baseDir, 'monkeyvideo10.jpg')
    fullfile(baseDir, 'monkeyvideo11.jpg')
    fullfile(baseDir, 'monkeyvideo12.jpg')
};


cfg = struct();

% ---- Stage timings ----
cfg.stage1Frac = 0.50;     % first 50% of time: FORWARD ONLY (save fun/boring)
cfg.stage2N    = 3;        % BACK ONLY duration (change this number as you want)

% ---- Back button behavior for this TASK ----
cfg.prevMode   = 'funOnly'; % when BACK is available, play ONLY fun videos, it can be switched to "boringOnly" for playing only boring ones and to "funOrBoring50" for playing mix of both

ptb_movie_eyelink_task_function(movieFiles, thumbFiles, 0, 1, 2, cfg);
%                                               useDummy stim main
