# cloudfoundry-mkappstack
simple automation to create a CF multi application stack

usage
=====

the artifact needs to be a zip file:
* containing app manifest.yml
* containing all other app files
* not enclosed by directory

configuration files:
* secret.mk should contain CF admin credentials
* appstack.mk contains all settings, including main manifest file name
* main manifest file (as in appstack.yml.tmpl)

targets:
* cfset - download and set up CF CLI binary
* deploy - install appstack in the CF org/space, according to the main manifest
* clean - wipe all local artifacts
* cfclean - wipe most of CF self-created objects
* wipeall - cfclean + clean
