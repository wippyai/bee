"""Public executable app transfer between two independent physical clients."""
from pathlib import Path
import tempfile,re,sys
from native_client import owner_handle,stop_owner
from native_workspace import NativeDesktop

def run(binary):
    with tempfile.TemporaryDirectory(prefix='bee-public-transfer-') as tmp:
        folder=Path(tmp);state=folder/'state';clients=[];owner=None
        try:
            first=NativeDesktop(binary,folder,state);clients.append(first)
            first.wait(' BEE ',timeout=15);owner=owner_handle(first,binary,state)
            first.open_start();first.choose('Terminal');first.wait('$ ')
            first.key(b"MOVE_STATE=retained; clear; printf 'MOVE_BEFORE_%s_END\\n' \"$$\"\r")
            first.wait('MOVE_BEFORE_')
            match=re.search(r'MOVE_BEFORE_(\d+)_END',first.text());assert match,first.text();pid=match[1]
            second=NativeDesktop(binary,folder,state);clients.append(second);second.wait(' BEE ',timeout=15)
            second.open_start();second.choose('Terminal');second.wait('$ ')
            second.key(b"NEIGHBOR_STATE=alive; clear; printf 'NEIGHBOR_%s_END\\n' \"$$\"\r");second.wait('NEIGHBOR_')
            second.key(b'\x1b[20~');second.wait('CONNECTION')
            row=next(i for i,line in enumerate(second.screen.display) if 'DISPLAY ' in line)
            label=re.search(r'[A-Z][a-z]+ [A-Z][a-z]+ · [0-9a-f]{8}',second.screen.display[row+1]);assert label,second.text()
            destination=label[0];second.key(b'\x1b')
            x=first.screen.display[0].index('Terminal')+1
            first.mouse(2,x,1);first.mouse(2,x,1,True);first.wait('Send to display');first.choose('Send to display')
            first.wait(destination);first.choose(destination);first.wait('No applications open')
            second.wait('MOVE_BEFORE_'+pid+'_END')
            for _ in range(3):
                second.key(b"printf 'MOVE_AFTER_%s_%s_END\\n' \"$MOVE_STATE\" \"$$\"\r")
                if 'MOVE_AFTER_retained_'+pid+'_END' in second.text():break
                second.key(b'\x1b\t')
            second.wait('MOVE_AFTER_retained_'+pid+'_END')
            second.key(b'\x1b\t');second.key(b"printf 'NEIGHBOR_AFTER_%s_END\\n' \"$NEIGHBOR_STATE\"\r");second.wait('NEIGHBOR_AFTER_alive_END')
            first.key(b'\x1b[24~');first.wait('No applications open')
            first.quit();second.quit()
            print('Public executable transfer: two independent native clients, real menu/friendly destination, exact shell PID/state, neighbor and source F12 passed',flush=True)
        finally:
            for ui in clients:
                ui.close()
            stop_owner(owner)

if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve())
