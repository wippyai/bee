"""Public-client Settings body resize regression, using disposable state."""
import sys, tempfile, time
from pathlib import Path
from native_workspace import NativeDesktop
from native_client import owner_handle, stop_owner
binary=Path(sys.argv[1]).resolve()
def bounds(ui):
    y,line=next((y,line) for y,line in enumerate(ui.screen.display) if 'Settings' in line and '×' in line)
    if '╭' not in line:
        return -1, 0, ui.width, ui.height
    left,right=line.index('╭'),line.index('╮')
    bottom=next(row for row in range(y+1,ui.height) if ui.screen.display[row][left]=='╰' and ui.screen.display[row][right]=='╯')
    return left,y,right,bottom

def filled(ui,label):
    until=time.monotonic()+3
    while time.monotonic()<until:
        ui.pump(.05)
        left,top,right,bottom=bounds(ui)
        status=[i for i,row in enumerate(ui.screen.display) if 'Theme:' in row]
        if status==[bottom-3]:
            print(label, 'frame', (left,top,right,bottom), 'footer',status,flush=True)
            return
    raise AssertionError(label+' footer does not track body\n'+ui.text())
with tempfile.TemporaryDirectory(prefix='bee-settings-resize-') as tmp:
    root=Path(tmp); state=root/'state'; owner=None
    ui=NativeDesktop(binary,root,state)
    try:
        ui.wait(' BEE ',timeout=15); owner=owner_handle(ui,binary,state)
        ui.open_start(); ui.choose('Settings'); ui.wait('BEE SETTINGS')
        filled(ui,'initial')
        for n in range(3):
            ui.window_control('□'); filled(ui,'maximized')
            ui.resize(130,42); filled(ui,'physical grow')
            ui.resize(90,28); filled(ui,'physical shrink')
            ui.window_control('◇'); filled(ui,'restored')
            left,top,right,bottom=bounds(ui)
            ui.mouse(0,right+1,bottom+1)
            ui.mouse(32,min(ui.width,right+9),min(ui.height,bottom+4))
            ui.mouse(0,min(ui.width,right+9),min(ui.height,bottom+4),True)
            filled(ui,'drag grow')
            left,top,right,bottom=bounds(ui)
            ui.mouse(0,right+1,bottom+1)
            ui.mouse(32,right-7,bottom-2)
            ui.mouse(0,right-7,bottom-2,True)
            filled(ui,'drag shrink')
            ui.key(b'\x1b[24~'); ui.wait('BEE SETTINGS'); filled(ui,'F12')
        ui.quit()
    finally:
        ui.close(); stop_owner(owner)
