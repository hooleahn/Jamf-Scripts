# Guided Dock Setup
This script sets a users dock up allowing the user to choose which apps are added.

Run as `./GuidedDockSetup.sh--test` to test it out.

It first shows the list of apps hardcoded in the script or passed via Jamf Pro policy parameters. Only installed apps are shown. Apps already in the Dock are pre-selected.

![First Step](https://github.com/hooleahn/Jamf-Scripts/blob/38cc2b9a2fc4b6d35f87a78fd9958e679f9db8e1/Guided%20Dock%20Setup/GuidedDockSetupStep1.png)

Then it asks the user if they want to remove non-business apps. These are hardcoded in the script, but can be modified. All are pre-selected.

![Second Step](https://github.com/hooleahn/Jamf-Scripts/blob/38cc2b9a2fc4b6d35f87a78fd9958e679f9db8e1/Guided%20Dock%20Setup/GuidedDockSetupStep2.png)
