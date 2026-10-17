import math
import os
_here = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(_here, 'lib_icons.py')).read())
I, LBL = {}, {}
def add(name, label, parts): I[name] = " ".join(parts); LBL[name] = label

# ── brand, outlined ───────────────────────────────────────────────────────────
W = [ring(12,12,9.3,1.8)]
for i in range(6):
    a = math.radians(i*60)
    W.append(capsule(12+2.0*math.cos(a),12+2.0*math.sin(a),12+7.9*math.cos(a),12+7.9*math.sin(a),1.5))
W += [ring(12,12,2.6,1.5)]
add('cockpit_wheel','AI Cockpit — outline', W)

R = [hexagon(12,12,9.4), hexagon(12,12,7.7,cw=False),
     capsule(9.3,6.9,9.3,17.1,1.6), ering(11.9,9.3,2.9,2.4,1.5), capsule(11.0,11.4,14.6,17.1,1.6)]
add('ruggi_site','Ruggi.Site — outline', R)

# ── brand, solid ──────────────────────────────────────────────────────────────
WS = [circle(12,12,9.3)]
for i in range(6):
    a = math.radians(i*60+30)
    WS.append(circle(12+5.2*math.cos(a), 12+5.2*math.sin(a), 2.15, cw=False))   # lightening holes
WS.append(circle(12,12,1.5,cw=False))
add('cockpit_wheel_solid','AI Cockpit — solid', WS)

RS = [hexagon(12,12,9.4),
      capsule(9.3,6.9,9.3,17.1,1.7,cw=False),                 # R stem, punched
      ellipse(11.9,9.3,3.0,2.5,cw=False), ellipse(11.9,9.3,1.3,1.1),   # bowl + counter
      capsule(11.0,11.6,14.6,17.1,1.7,cw=False)]              # leg, punched
add('ruggi_site_solid','Ruggi.Site — solid', RS)

# ── concepts ──────────────────────────────────────────────────────────────────
B = [ering(13.2,13.8,6.0,4.3,1.45,rot=-12),
     capsule(12.1,10.6,13.0,17.3,1.15), capsule(15.2,11.4,15.9,16.3,1.15),
     ring(5.9,12.2,2.35,1.35),
     capsule(5.0,10.2,3.6,7.6,0.85), capsule(6.9,10.0,7.9,7.4,0.85),
     circle(3.4,7.2,0.72), circle(8.1,7.0,0.72),
     ering(11.4,6.6,3.1,1.7,0.85,rot=-28), ering(16.9,7.4,2.7,1.5,0.85,rot=10)]
add('bee','bee', B)

A = [hexagon(12,12,9.3), hexagon(12,12,7.8,cw=False)]
nodes = [(12,6.9),(7.0,14.6),(17.0,14.6)]
for i,(x,y) in enumerate(nodes):
    nx,ny = nodes[(i+1)%3]; A.append(capsule(x,y,nx,ny,1.0))
for x,y in nodes: A.append(ring(x,y,2.05,1.1))
add('autocognition','AutoCognition', A)

C = [ring(9.0,12,6.5,1.5)]
for i in range(6):
    a = math.radians(i*60+15)
    C.append(capsule(9.0+1.5*math.cos(a),12+1.5*math.sin(a),9.0+5.4*math.cos(a),12+5.4*math.sin(a),1.2))
C += [ring(9.0,12,1.95,1.1), chevron(17.6,12,3.0,1.35), chevron(20.8,12,3.0,1.35)]
add('autopilot_cruise','Autopilot Cruise', C)

P = [capsule(3.0,6.6,10.5,12.0,1.45), capsule(3.0,17.4,10.5,12.0,1.45),
     circle(3.0,6.6,1.25), circle(3.0,17.4,1.25),
     poly([(12.6,12.0),(18.4,5.6),(16.3,11.0),(20.6,11.0),(14.8,18.4),(16.9,12.8),(12.6,12.8)])]
add('power_combo','Power Combo', P)

# Everywhere relay: phone, waves, rig
E = [rframe(2.4,5.2,7.2,13.6,1.6,1.4), capsule(4.6,16.4,7.2,16.4,0.9),
     rframe(16.4,8.2,5.4,8.0,1.3,1.35),
     arcband(11.6,12,2.6,1.1,-52,52), arcband(11.6,12,4.6,1.1,-46,46)]
add('everywhere_relay','Everywhere relay', E)

# Marketplace: awning + shopfront
M = [poly([(2.6,9.4),(4.8,5.2),(19.2,5.2),(21.4,9.4)]),
     poly([(5.2,9.4),(7.4,5.2),(9.0,5.2),(7.6,9.4)], cw=False),
     poly([(11.2,9.4),(12.4,5.2),(14.0,5.2),(13.6,9.4)], cw=False),
     poly([(17.2,9.4),(17.0,5.2),(18.6,5.2),(19.6,9.4)], cw=False),
     rframe(4.2,10.6,15.6,8.4,1.4,1.4), rframe(8.6,13.4,6.8,5.6,1.0,1.3)]
add('marketplace','Marketplace', M)

# Bookshelf — spines with head/tail bands and one leaning. Three plain bars on a
# baseline is a BAR CHART, which is exactly what the first draft looked like;
# the bands and the leaning book are what make it read as books.
S = [capsule(2.4, 20.4, 21.6, 20.4, 1.5)]
for x, ytop, w in ((3.2, 6.2, 3.7), (7.3, 8.6, 3.3), (11.0, 4.9, 3.9)):
    h = 19.6 - ytop
    S.append(rframe(x, ytop, w, h, 0.7, 1.25))
    S.append(capsule(x+0.55, ytop+2.6, x+w-0.55, ytop+2.6, 0.85))
    S.append(capsule(x+0.55, ytop+h-2.4, x+w-0.55, ytop+h-2.4, 0.85))
S.append(rot_frame(17.6, 13.6, 3.5, 11.6, 17, 1.25))
S.append(rot_capsule(18.36, 9.4, 2.4, 0.85, 17))
S.append(rot_capsule(18.8, 18.0, 2.4, 0.85, 17))
add('bookshelf','Bookshelf', S)

# Dossier: document + magnifier
D = [rframe(3.6,3.2,12.4,15.6,1.5,1.4),
     capsule(6.4,7.4,13.2,7.4,1.0), capsule(6.4,10.4,13.2,10.4,1.0), capsule(6.4,13.4,10.6,13.4,1.0),
     ring(16.4,16.0,4.2,1.4), capsule(19.3,18.9,21.6,21.2,1.6)]
add('dossier','Dossier', D)

# Intercom: mic + sound
N = [rframe(9.4,2.6,5.2,10.4,2.6,1.4),
     arcband(12,12.0,5.4,1.4,20,160), capsule(12,17.4,12,20.6,1.4), capsule(8.8,20.6,15.2,20.6,1.4)]
add('intercom','Intercom', N)

# Margin: text with a margin rule and a pen
G = [capsule(3.0,5.0,3.0,19.0,1.3),
     capsule(6.6,7.0,19.4,7.0,1.2), capsule(6.6,11.0,19.4,11.0,1.2), capsule(6.6,15.0,14.0,15.0,1.2),
     poly([(15.4,20.4),(16.2,17.0),(21.0,12.2),(22.4,13.6),(17.6,18.4)])]
add('margin','Margin', G)

# Workers cascade
K = [rframe(2.6,3.4,9.0,5.2,1.2,1.3), rframe(7.4,9.4,9.0,5.2,1.2,1.3), rframe(12.2,15.4,9.0,5.2,1.2,1.3),
     capsule(11.9,6.2,12.6,9.0,1.1), capsule(16.7,12.2,17.4,15.0,1.1)]
add('workers_cascade','Workers cascade', K)

# Stand-alone: one machine, nothing beyond it
T = [rframe(3.4,4.2,17.2,11.6,1.6,1.45), capsule(12,15.8,12,18.4,1.3), capsule(7.6,19.4,16.4,19.4,1.5),
     circle(12,10.0,2.0)]
add('standalone','Stand-alone', T)

# Pre-release: seal with a clock
Q = [ring(12,10.6,6.6,1.5), capsule(12,10.6,12,7.4,1.15), capsule(12,10.6,14.6,10.6,1.15),
     poly([(8.0,16.2),(8.0,21.6),(12.0,19.4),(16.0,21.6),(16.0,16.2)]),
     poly([(9.4,16.2),(9.4,19.2),(12.0,17.8),(14.6,19.2),(14.6,16.2)], cw=False)]
add('pre_release','Pre-release', Q)

# Dual: two models answering
U = [ring(9.0,12,5.6,1.5), ring(15.0,12,5.6,1.5)]
add('dual','Dual', U)

out = os.path.normpath(os.path.join(_here, '..'))
for n, d in I.items():
    open(os.path.join(out, 'ck_' + n + '.svg'), 'w').write(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">'
        f'<path fill="currentColor" d="{d}"/></svg>\n')
print('wrote %d svgs to %s' % (len(I), out))
print('  ' + ', '.join('ck_' + n for n in I))
print('now: bash Installs/build_icon_font.sh  (or merge_custom_icons.py on the current font)')
