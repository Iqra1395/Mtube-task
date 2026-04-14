
# Mtube-task Description:

The task (version 1) is about playing videos for monkey.
Following are the features of the task:
Two arrow keys at left (backward) or right (forward) of the screen are for playing previous or next video respectively through eye saccade to the key. The key will turn red from green (right) and blue (left), upon looking at it. The dwell time is 1.20 seconds.
If no button is selected, three thumbnails will appear on screen at the end of video, video will be selected on the basis if saccade to thumbnail. If no thumbnail is selected random video will be played.
Previous videos (left arrow) represents fun/boring videos and next video (right arrow) represents any new video not watched before.
The criteria for fun video is 1 full watch of video and boring is any video skipped to next any time.


The task is divided into three parts:
1. First 50% of the task is storing fun/boring videos. 
        only forward (right) key will appear, skipping the video will store it in boring ones and watching it full will store it in fun videos.

2. Next 25% of the task is for playing from the stored videos, only backward (left) key will appear, it will play from one of the following (can be set in code)
        only fun 
        only boring
        mix of the two

3. Last 25% of the task, both arrow keys will appear to play from familiar (fun/boring stored) or new (from unknown ones)



The log for how many fun/boring/unknown videos number will be displayed at the top left corner of screen.

the tutorial video for the task can be found in this link "https://drive.google.com/file/d/1gsYm-qW00CpnBhHlVcOrDR8ta6lHA60Z/view?usp=sharing"


thumbnails used in the code are given in the folder here and few sample videos are also uploaded in the videos folder in the repository. 
