This github-actions workflow creates a container with preinstalled R, Rstudio-server, OMA packages and other packages as requested by users.

## File descriptions:

1. [rstudio-server.def](rstudio-server.def)
2. [launcher.sh](launcher.sh)
3. [launcher_rserver.desktop](launcher_rserver.desktop)
4. [installed_packages.tsv](installed_packages.tsv)
5. [git-cmds](git-cmds)
6. [.github/workflows/release-on-tag.yml](.github/workflows/release-on-tag.yml)

After successful run of github actions this will create a container `rstudio-server.sif` which can be downloaded from [release page](https://github.com/microDM/OMA-Rstudio-server/releases).

## Using container on SD-Desktop:

### For project managers

Follow these steps:

1. Upload `rstudio-server.sif`, `launcher.sh` and `launcher_rserver.desktop` on SD-connect.
2. Move above files to one location (ex: /media/volume/OMA_container/OMA-rserver) which should be accessible for every user.

### For other users

1. Copy launcher desktop shortcut `/media/volume/OMA_container/OMA-rserver/launcher_rserver.desktop` to your desktop location `/home/$USER/Desktop`
2. Right click on desktop shortcut file and select *'Allow launching'*. After which the icon will be renamed to *'Rstudio Server (OMA)'*
3. Double click on icon, this will open a terminal printing the launch details. Wait for some seconds, Rstudio server will open in firefox.

## File structure inside new containers (Rstudio-server)


| |Inside container (Rstudio)|Location on drive|Description|
|---|---|---|---|
|**User specific directories**|`/home/$USER`|`/home/$USER`|All user files. Will not be accessible by other users. Can be used to store codes/analysis.|
|**Workspaces**|`/home/$USER/Workspace`|`/media/volume/Workspaces/users/$USER`|This folder is accessible for every user. You can store codes which you want to share with other users.|
|**Exports**|`/home/$USER/Exports`|`/media/volume/Exports/users/$USER`|This folder is intended for storing files which you want to export. This is also accessible for other users.|
|**Shared-projects (read-only)**|`/media/project_2013220` or `/home/$USER/shared_project`|`/media/volume/project_2013220`|All files from SD-connect are copied in this folder and TSE objects are accessible|
|**SD-connect (read-only)**|`/home/$USER/Projects/SD-Connect`|`/home/$USER/Projects/SD-Connect`|Mounted SD-connect drive|


<!-- BEGIN: INSTALLED_PACKAGES -->

<!-- END: INSTALLED_PACKAGES -->
