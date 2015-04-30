include *.mk

# defaults for external programs and others
SHELL = /bin/bash
ruby = ruby -ryaml -e
curl = curl -s -k -L -x $(proxy) --noproxy $(noproxy)
unzip = unzip -q -DD
appmfst = cfdepl.yml
shmute = >/dev/null 2>&1

cfarchive = $(cfbindir)/cfbin-$(cfbinrel)-$(cfbinver).tar.gz
cfbinary = $(cfbindir)/cf-$(cfbinrel)-$(cfbinver)
cfcmd = $(cfbindir)/cf

ifeq (, $(shell which ruby))
 $(error "No ruby in $(PATH), consider doing apt-get install ruby")
endif
ifeq (,$(proxy))
  cfcall = $(cfcmd)
else
  cfcall = env HTTP_PROXY=$(proxy) $(cfcmd)
endif
ifeq ($(cfbinver),latest)
  cfarcurl = "$(cfbinurl)?release=$(cfbinrel)"
else
  cfarcurl = "$(cfbinurl)?release=$(cfbinrel)&version=$(cfbinver)"
endif

# functions
r_ymllistdo = $(ruby) 'YAML.load(File.open("$(1)"))$(2).each { |app| $(3) }'
r_appgetattr = $(ruby) 'puts YAML.load(File.open("$(1)"))$(2).uniq.find { |app| $(3) }$(4)'
r_mergeymls = 'myapp=YAML.load(File.open("$(1)")); \
              ovrd=YAML.load(File.open("$(2)"))["applications"].uniq.find { |app| app["name"]=="$(3)" }; \
              myapp["applications"]=[myapp["applications"][0].merge(ovrd)]; \
              puts YAML.dump(myapp)'
i_dircrte = [$(stackpfx)] ----->[dir] $(1) directory create
i_cfdwnld = [$(stackpfx)] »»»»»»[cli] cf cli download
i_cfunzip = [$(stackpfx)] ..ooOO[cli] cf cli binary uncompress
i_apppush = [$(stackpfx)] ----->[app] $(1) push
i_appnchg = [$(stackpfx)] ======[app] $(1) already up to date
i_appdnld = [$(stackpfx)] »»»»»»[app] $(1) artifact download
i_appunzp = [$(stackpfx)] ..ooOO[app] $(1) artifact uncompress
i_svccrte = [$(stackpfx)] ----->[svc] $(1) user-provided-service create
i_svcupdt = [$(stackpfx)] --><--[svc] $(1) user-provided-service update

.PHONY: all
.PRECIOUS: %/.dir $(srcdir)/%.zip $(appdir)/%/manifest.yml $(appdir)/%/$(appmfst)

all: appstack

clean:
		rm -rf $(cfbindir) $(srcdir) $(appdir)

APPS := $(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),print "$(appdir)/"+app["name"]+"/.app " ))
SVCS := $(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),if app["env"].has_key?("$(stackpfx)svcname"); print "$(appdir)/"+app["name"]+"/.svc " end))

#$(info APPS: $(APPS))
#$(info SVCS: $(SVCS))

appstack: $(SVCS) $(APPS)
#		@echo SVCS: $(SVCS)
#		@echo APPS: $(APPS)

cfset: $(cfcmd)
		@$(cfcall) login -u $(cfuser) -p "$(cfpass)" -a $(cfapi) -o $(cforg) -s $(cfspace) --skip-ssl-validation >/dev/null
		$(info [$(stackpfx)] cf authenticated user: $(cfuser), API: $(cfapi), Org: $(cforg), Space: $(cfspace))

%/.dir:
		$(info $(call i_dircrte,$(@D)))
		@mkdir -p $(@D)
		@touch $@

$(appdir)/%/.svc: $(appdir)/%/.app
		$(eval svcname:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)svcname"])))
		$(eval locsvcparams:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)svcparams"])))
		$(eval remoteparams:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/^$(stackpfx)svcparams:\ /{print $$2}'))
		$(eval remoteurl:=$(shell $(cfcall) app $(subst $(appdir)/,,$(@D)) |awk '/^urls:\ /{gsub(",","");print $$2}'))
		$(eval boundapps:=$(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),if app["services"]; if app["services"].include?("$(svcname)"); print app["name"]+" " end end )))
		@if [ "$(locsvcparams)" ]; then svcparams=$(svcparams); else svcparams='{"host":"http://$(remoteurl)/"}'; fi; \
                if [ "$$svcparams" != '$(remoteparams)' ]; then $(cfcall) set-env $(subst $(appdir)/,,$(@D)) $(stackpfx)svcparams $${svcparams} $(shmute); fi; \
                if [ "`$(cfcall) services | grep '^$(svcname)\ '`" ]; then \
                  echo "$(call i_svcupdt,$(svcname))"; \
                  $(cfcall) uups $(svcname) -p $${svcparams} $(shmute); \
                  for boundapp in $(boundapps); do \
                    if [ "`$(cfcall) apps | grep "^$${boundapp}\ "`" ]; then \
                      echo "[$(stackpfx)] --><--[app] $${boundapp} restage"; \
                      $(cfcall) unbind-service $${boundapp} $(svcname) $(shmute); \
                      $(cfcall) bind-service $${boundapp} $(svcname) $(shmute); \
                      $(cfcall) restage $${boundapp} $(shmute); \
                    fi \
                  done \
                else \
                  echo "$(call i_svccrte,$(svcname))"; \
                  $(cfcall) cups $(svcname) -p $${svcparams} $(shmute); \
                fi; \

$(appdir)/%/.app: $(appdir)/%/$(appmfst) | $(appdir)/%/.changed
		@if [ -f $| ]; then \
		  echo "$(call i_apppush,$(subst $(appdir)/,,$(@D)))"; \
                  $(cfcall) push -p $(@D) -f $(@D)/$(appmfst) $(shmute); \
                else \
                  echo "$(call i_appnchg,$(subst $(appdir)/,,$(@D)))"; \
                fi

$(appdir)/%/.changed: $(appdir)/%/.domain | cfset
		$(eval localver:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)version"])))
		$(eval remotever:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/^$(stackpfx)version:\ /{print $$2}'))
		$(eval localmem:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["memory"]) |sed 's/[A-Za-z]//g'))
		$(eval remotemem:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/"mem":/{print $$2}'))
		@if [ '$(localver)' != '$(remotever)' ]; then touch $@; fi
		@if [ '$(localmem)' != '$(remotemem)' ]; then touch $@; fi
		@[ `cat $(@D)/.localdomain` = "nil" ] || $(cfcall) app $(subst $(appdir)/,,$(@D)) | grep -q `cat $(@D)/.localdomain` || touch $@


$(appdir)/%/.localdomain: $(appdir)/%/$(appmfst)
		@$(call r_appgetattr,$<,$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["domain"]) >$@

$(appdir)/%/.domain: $(appdir)/%/.localdomain | cfset
		@$(cfcall) domains | awk '{if (NR>2) print $$1}' >$@
		@[ `cat $<` = "nil" ] || grep -q `cat $<` $@ || $(cfcall) create-domain $(cforg) `cat $<`

$(appdir)/%/$(appmfst): $(appdir)/%/manifest.yml $(stackyml)
		$(info [$(stackpfx)] creating manifest for $(subst $(appdir)/,,$(@D)))
		@$(ruby) $(call r_mergeymls,$<,$(stackyml),$(subst $(appdir)/,,$(@D))) >$@

$(appdir)/%/manifest.yml: $(appdir)/%/.dir | $(srcdir)/%.zip
		$(info $(call i_appunzp,$(subst $(appdir)/,,$(@D))))
		@$(unzip) -d $(@D) $|

$(srcdir)/%.zip: $(srcdir)/.dir
		$(info $(call i_appdnld,$(basename $(@F))))
		@$(curl) -o $@ `$(call r_appgetattr,$(stackyml),$(yml_appseq),app["name"]=="$(basename $(@F))",["env"]["$(stackpfx)srcurl"])`

# the recipes below are for setting up Cloud Foundry CLI binary
$(cfarchive): | $(cfbindir)/.dir
		$(info $(call i_cfdwnld))
		@$(curl) -o $@ $(cfarcurl)

$(cfbinary): $(cfarchive)
		$(info $(call i_cfunzip))
		@tar -C $(cfbindir) -xzmf $<
		@mv $(cfbindir)/cf $@

$(cfcmd): $(cfbinary)
		@ln -fs $(<F) $@

