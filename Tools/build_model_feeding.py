"""Register generated poses without changing the PNG pixels.

Each cel uses its measured, non-overlapping atlas rectangle. A per-sheet pixel
scale plus anatomical ground/mouth anchors prevents packing gaps from becoming
pose jitter. Source rectangles are top-left; display coordinates use the
application's 1402 x 1122 logical canvas.
"""
from pathlib import Path
import copy
import json

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / 'Assets'
BASE = 'character-model/v1/'
MANIFEST = ASSETS / 'pet-animations.json'
data = json.loads(MANIFEST.read_text())

# Absolute atlas coordinates, including two pixels of alpha padding where safe.
bounds = {
    # One identity-locked 4 x 4 master. The normalized file only removes the
    # generator's fully transparent 1 px right / 3 px bottom remainder.
    'feed-master-v1-normalized': [[(i % 4) * 315, (i // 4) * 311, (i % 4 + 1) * 315 - 1,
                                   (i // 4 + 1) * 311 - 1] for i in range(16)],
    'feed-master-blink-v3': [[0,0,314,310]],
    'rise-coat-v8': [[78,7,508,467],[577,8,1023,467],[1092,6,1523,467],
                      [67,471,511,991],[579,472,1024,992],[1092,472,1525,991]],
    'idle-bridge-v1': [[69,7,511,514],[583,11,1011,514],[1069,8,1503,514],
                       [20,516,491,1000],[529,516,997,1003],[1033,516,1511,1008]],
    'jump-proportions-v2': [[116,38,469,389],[594,73,951,383],[1094,18,1424,391],[1571,22,1903,336],
                            [110,411,442,731],[604,410,953,767],[1108,444,1472,762],[1582,407,1939,767]],
    'sit-stand': [[195,18,646,510], [837,13,1290,510], [189,557,662,1080], [840,559,1307,1083]],
    'chew': [[111,4,483,390], [593,5,965,390], [1071,4,1442,390], [1552,6,1929,390],
             [111,394,484,777], [592,394,963,777], [1068,392,1445,777], [1552,394,1929,777]],
    'jump': [[79,8,455,394], [571,64,937,389], [1064,8,1405,394], [1559,8,1901,344],
             [75,403,414,752], [576,408,932,771], [1069,453,1439,781], [1565,403,1942,788]],
    'turn': [[63,3,427,398], [501,7,921,397], [983,15,1453,397], [1485,16,1963,398],
             [44,405,461,782], [572,406,877,782], [1084,405,1408,776], [1584,416,1936,770]],
    'turn-back-steps': [[61,10,408,373],[507,7,902,373],[953,6,1382,373],
                        [3,376,440,727],[477,376,893,727],[940,384,1374,725],
                        [35,738,423,1089],[523,728,880,1095],[1018,730,1341,1092]],
    'return-front-steps': [[115,3,418,374],[509,3,845,371],[952,27,1367,374],
                          [29,381,411,714],[497,380,893,725],[952,382,1364,727],
                          [54,725,423,1103],[514,730,873,1102],[1016,727,1350,1107]],
}
scales = {'sit-stand': 2.06, 'chew': 2.617, 'jump': 2.804, 'turn': 2.739,
          'turn-back-steps': 2.96, 'return-front-steps': 2.88,
          'rise-coat-v8':2.10, 'idle-bridge-v1':2.13, 'jump-proportions-v2':2.96,
          'feed-master-v1-normalized': 3.75, 'feed-master-blink-v3': 3.75}
anchors = {
    # Root points are between the supporting paws. Airborne frames keep the
    # same implied floor root, so their drawn paw height remains intentional.
    'feed-master-v1-normalized': [[145,288],[143,287],[145,287],[145,286],
                                  [140,292],[150,292],[150,292],[140,292],
                                  [145,288],[145,288],[145,288],[145,288],
                                  [145,291],[154,290],[151,290],[155,289]],
    'feed-master-blink-v3': [[145,288]],
    'rise-coat-v8': [[243,462],[752,462],[1264,462],[243,985],[754,987],[1265,986]],
    'idle-bridge-v1': [[249,511],[765,511],[1256,511],[210,995],[722,998],[1234,1003]],
    'jump-proportions-v2': [[252,385],[748,379],[1244,387],[1716,387],
                            [250,763],[745,763],[1250,758],[1719,763]],
    'sit-stand': [[364,508],[1014,508],[364,1078],[1014,1081]],
    'chew': [[250,389],[731,389],[1210,389],[1693,389],[250,776],[731,776],[1210,776],[1693,776]],
    # The ground stays below the tucked airborne paws; do not pin those paws to it.
    'jump': [[230,392],[725,392],[1220,392],[1715,392],[230,788],[725,788],[1220,788],[1715,788]],
    'turn': [[210,396],[720,395],[1230,395],[1740,396],[265,780],[730,780],[1195,774],[1705,768]],
    # Register contact groups, not bounding-box centers. In the forward turn,
    # the screen-right forepaw stays put through the first lifted-paw steps;
    # the near hind paw becomes the support through the final three poses.
    'turn-back-steps': [[200,369],[680,369],[1140,369],[208,725],[678,725],
                        [1160,723],[250,1087],[660,1093],[1133,1090]],
    'return-front-steps': [[242,371],[684,369],[1133,372],[250,712],[700,723],
                          [1160,725],[210,1101],[665,1100],[1140,1105]],
}
mouths = {
    'feed-master-v1-normalized': [[145,128],[143,137],[145,125],[145,123],
                                  [140,187],[150,105],[150,111],[140,180],
                                  [145,130],[145,132],[145,130],[140,133],
                                  [145,113],[132,116],[58,106],[155,105]],
    'feed-master-blink-v3': [[145,128]],
    'rise-coat-v8': [[246,218],[752,226],[1264,225],[245,700],[754,700],[1265,701]],
    'idle-bridge-v1': [[249,210],[762,213],[1241,212],[178,709],[686,711],[1196,718]],
    'jump-proportions-v2': [[252,177],[748,217],[1233,155],[1710,167],
                            [249,549],[744,550],[1252,588],[1718,549]],
    'sit-stand': [[364,220],[1014,208],[364,762],[1014,777]],
    'chew': [[250,164],[731,171],[1210,165],[1693,178],[248,558],[731,554],[1210,531],[1693,554]],
    'jump': [[230,172],[725,225],[1220,169],[1715,171],[230,565],[725,572],[1220,622],[1715,564]],
    'turn': [[210,169],[585,160],[1030,170],[1525,175],[105,550],[620,550],[1195,550],[1705,550]],
    'turn-back-steps': [[198,154],[575,148],[1018,152],[56,526],[535,534],
                        [1000,534],[95,880],[580,880],[1133,880]],
    'return-front-steps': [[242,160],[560,156],[1009,175],[88,530],[554,538],
                          [1012,543],[152,875],[619,883],[1140,870]],
}
frames = {}
for name, rects in bounds.items():
    scale = scales[name]
    frames[name] = []
    for i, (x0,y0,x1,y1) in enumerate(rects):
        ax, ay = anchors[name][i]
        mx, my = mouths[name][i]
        local_coordinates = name == 'feed-master-v1-normalized'
        frames[name].append({
            'file': BASE + 'feeding/' + name + '.png',
            'sourceRect': [x0,y0,x1-x0+1,y1-y0+1],
            'displaySize': [round((x1-x0+1)*scale,3),round((y1-y0+1)*scale,3)],
            'anchor': [round((ax if local_coordinates else ax-x0)*scale,3),
                       round((ay if local_coordinates else ay-y0)*scale,3)],
            'mouth': [round((mx if local_coordinates else mx-x0)*scale,3),
                      round((my if local_coordinates else my-y0)*scale,3)],
        })

frames['wipe'] = []
for i in range(8):
    frames['wipe'].append({'file': BASE+'wipe-keyframes.png',
        'sourceRect': [(i%4)*495,(i//4)*396,495,396],
        'displaySize': [1336.5,1069.2], 'anchor': [648,1026], 'mouth': [648,426.6]})

def cel(group, index, duration):
    frame = copy.deepcopy(frames[group][index]); frame['duration'] = duration
    return frame

def clip(name, sequence, loop=False):
    data['clips'][name] = {'loop':loop,'provisional':True,'blendFrames':False,
                          'frames':[cel(*item) for item in sequence]}

frames['idle'] = [copy.deepcopy(data['clips']['Idle']['frames'][0])]
# The 2026-11-12 identity repair deliberately uses one atlas for every pose in
# the feeding performance. Earlier versions aligned five separately generated
# cats at their feet; the boundary was mechanically continuous but the face,
# torso and coat still popped. Here the pose changes while the character does not.
master = 'feed-master-v1-normalized'
seat = (master,0,.12)
stand = (master,12,.12)
rise = [seat]+[(master,i,d) for i,d in zip([1,2,3,12],[.12,.12,.12,.14])]
sit = [stand]+[(master,i,d) for i,d in zip([2,1,0],[.12,.12,.16])]
face = [('idle',0,.12),stand]
relax = [stand,('idle',0,.16)]
clip('FaceCard',face)
clip('EnterAwait',face+sit[1:])
clip('ExitAwait',rise+relax[1:])
clip('AwaitInput',[(master,0,1.35),('feed-master-blink-v3',0,.12),(master,0,1.25)],loop=True)
clip('FeedStart',[(master,0,.55)])
clip('Rise',rise)
clip('CatchCard',[stand,(master,4,.14),(master,5,.13),(master,6,.18),
                  (master,5,.10),(master,7,.16)])
clip('Settle',[(master,7,.12),(master,4,.12),(master,3,.10),
               (master,2,.11),(master,1,.12),(master,0,.18)])
clip('Eat',[(master,0,.12),(master,8,.12),(master,9,.13),(master,8,.12),
            (master,9,.13),(master,8,.12),(master,9,.13),(master,8,.16)])
clip('Swallow',[(master,8,.08),(master,9,.10),(master,8,.12),(master,0,.18)])
clip('WipeMouth',[(master,0,.18),(master,10,.15),(master,11,.24),
                  (master,10,.17),(master,11,.22),(master,10,.16),
                  (master,8,.18),(master,0,.18)])
clip('StandAfterWipe',[(master,0,.10),(master,1,.12),(master,2,.12),stand])
# The body, shoulders and hindquarters change view between cels; no whole-sprite
# rotation is applied. Return uses the same identity-locked physical poses.
clip('TurnBack',[(master,12,.14),(master,13,.18),(master,14,.20),(master,15,.20)])
clip('Poop',[(master,15,.82)])
clip('ReturnFront',[(master,15,.16),(master,14,.20),(master,13,.18),(master,12,.16)])
clip('Proud',[(master,12,.10),(master,2,.12),(master,1,.12),
              (master,0,.22),('feed-master-blink-v3',0,.12),(master,0,.34)])
data['formatNotes'] = {'sourceRectOrigin':'top-left',
    'displaySize':'logical size of a tightly packed cel; does not stretch it to the full canvas',
    'anchors':'logical top-left cel coordinates; fixed anatomical root and ground',
    'modelVersion':'character-model-v1-feed-master-v1', 'animationStatus':'integrated-for-review',
    'identity':'All feeding poses come from one 4x4 identity-locked master atlas.',
    'turns':'Body-drawn front, three-quarter, side-back and back poses; no rotation transform.'}
MANIFEST.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
(ASSETS / BASE / 'feeding' / 'registration.json').write_text(json.dumps({
    'canvas':[1402,1122], 'frames':frames, 'pixelScales':scales,
    'notes':'Original PNGs remain unchanged; measured atlas regions and anatomical anchors are consumed by the renderer.'
},ensure_ascii=False,indent=2)+'\n')
print('Updated clips:',len(data['clips']))
