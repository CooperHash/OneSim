import subprocess,time,json,sys
adb='/Users/cooper/Downloads/platform-tools/adb'
serial=sys.argv[1] if len(sys.argv)>1 else 'emulator-5554'
start=time.time()
subprocess.run([adb,'-s',serial,'shell','am','start','-a','android.settings.SETTINGS'],stdout=subprocess.DEVNULL)
for i in range(30):
 subprocess.run([adb,'-s',serial,'shell','input','swipe','900','1400' if i%2==0 else '600','900','600' if i%2==0 else '1400','350'],stdout=subprocess.DEVNULL)
 time.sleep(.25)
print(json.dumps({'start':start,'end':time.time(),'swipes':30}))
