<p>This is a fork from the original developer Stossy11. StosDebug is a JIT Enabler for iOS/iPadOS and nothing else. No extra fluff. This fork supports both Personalized Developer Disk Images and Cryptex Developer Disk Images that are required by newer Apple devices. This should support iOS/iPadOS 17.4+ (including iOS/iPadOS 27).</p>
<p>&nbsp;</p>
<p>What I added/changed:</p>
<ul>
<li>Removes the special Manic Emu .jitrpl JIT script so Manic Emu can use Universal.js</li>
<li>Adds Cryptex Support for DDI. All devices should be able to mount the DDI properly now</li>
<li>Adds CFBundleURLSchemes for "stikdebug://" and "stikjit://" on top of "stosdebug://" so apps that call other JIT Enablers will be able to call this one.</li>
<li>Adds ability to decode StikDebug URLs for JIT requests. If a base64 script is not provided in the decoded URL, it will default to Universal.js.</li>
<li>Fixes TXM checks for TXM capable devices. Prior it would fail and you would need to ForceTXM using the Toggle in Settings. No need for that now. Force TXM toggle will reappear if for any reason the TXM Checks do fail again.</li>
<li> Fixes background location keep-alive</li>
<li> Add background audio keep-alive as a fallback</li>
<li> Add toggles for Location and Audio keep-alives</li>
<li>Both keep-alive options will terminate once JIT Script finishes running. Prevents app from indefinitely staying in the background</li>
<li>JS Window View is now Observable and updates window with each subsequent JIT launch.</li>
</ul>
<p>I think that's about it.</p>
<p>Enjoy.</p>
<p align="center">
  <img width="330" height="717" alt="App" src="https://github.com/user-attachments/assets/6fda88c4-de35-45f2-8f38-83f0e5b2d09f" />
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img width="330" height="717" alt="Setting" src="https://github.com/user-attachments/assets/5dbca5fc-9cd3-4eb3-86fa-1c6087ccb217" />
</p>
