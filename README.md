<p>This is a fork from the original developer Stossy11. StosDebug is a JIT Enabler for iOS/iPadOS and nothing else. No extra fluff. This fork supports both Personalized Developer Disk Images and Cryptex Developer Disk Images that are required by newer Apple devices. This should support iOS/iPadOS 17.4+ (including iOS/iPadOS 27).</p>
<p>&nbsp;</p>
<p>What I added/changed:</p>
<ul>
<li>Removes the special Manic Emu .jitrpl JIT script so Manic Emu can use Universal.js</li>
<li>Adds Cryptex Support for DDI. All devices should be able to mount the DDI properly now</li>
<li>Adds CFBundleURLSchemes for stikdebug:// and stikjit:// so apps that call other JIT Enablers will be able to call this one. No reason someone would use multiple JIT enablers on one device anyway. Shouldn't conflict. App still has stosdebug:// CFBundleURLSchemes.</li>
<li>Fixes TXM checks for TXM capable devices. Prior it would fail and you would need to ForceTXM using the Toggle in Settings. No need for that now. Force TXM toggle will reappear if for any reason the TXM Checks do fail again.</li>
</ul>
<p>I think that's about it.</p>
<p>Enjoy.</p>
<img width="330" height="717" alt="Apps" src="https://github.com/user-attachments/assets/2e26b9ac-7e65-4213-ae41-3e0104523d25" />
<img width="330" height="717" alt="Settings" src="https://github.com/user-attachments/assets/57884b2e-5fde-4e75-aa37-411c19ade9c4" />
