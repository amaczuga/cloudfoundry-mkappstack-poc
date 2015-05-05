include *.mk

# defaults for external programs and others
SHELL = /bin/bash
ruby = ruby -ryaml -e
curlcmd = curl -s -k -L
unzip = unzip -q -DD
appmfst = cfdepl.yml

cfarchive = $(cfbindir)/cfbin-$(cfbinrel)-$(cfbinver).tar.gz
cfbinary = $(cfbindir)/cf-$(cfbinrel)-$(cfbinver)
cfcmd = $(cfbindir)/cf

ifdef TRACE
  shmute =
  nulout =
else
  shmute = @
  nulout = >/dev/null 2>&1
endif
ifeq (, $(shell which ruby))
  $(error "No ruby in $(PATH), consider doing apt-get install ruby")
endif
ifeq (,$(proxy))
  cfcall = $(cfcmd)
  curl = $(curlcmd)
else
  cfcall = env HTTP_PROXY=$(proxy) $(cfcmd)
  curl = $(curlcmd) -x $(proxy) --noproxy $(noproxy)
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
s_unquote = sed -e 's/"\|'\''//g' <<<
i_dircrte = [$(stackpfx)] ----->[dir] create: $(1) 
i_cfdwnld = [$(stackpfx)] »»»»»»[cli] download
i_cfunzip = [$(stackpfx)] ..ooOO[cli] binary uncompress
i_apppush = [$(stackpfx)] ----->[app] push: $(1)
i_apprstg = [$(stackpfx)] --><--[app] restage: $(1)
i_appnchg = [$(stackpfx)] ======[app] up to date: $(1)
i_appdnld = [$(stackpfx)] »»»»»»[app] download artifact: $(1)
i_appunzp = [$(stackpfx)] ..ooOO[app] uncompress artifact: $(1)
i_appdele = [$(stackpfx)] xxxxxx[app] delete: $(1)
i_svccrte = [$(stackpfx)] ----->[svc] create user-provided-service: $(1)
i_svcupdt = [$(stackpfx)] --><--[svc] update user-provided-service: $(1)
i_svcdele = [$(stackpfx)] xxxxxx[svc] delete: $(1)

.PHONY: all
.PRECIOUS: %/.dir $(srcdir)/%.zip $(appdir)/%/manifest.yml $(appdir)/%/$(appmfst)

APPS := $(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),print app["name"]+" " ))
CRTAPPS := $(foreach crtapp,$(APPS),$(appdir)/$(crtapp)/.app)
DELAPPS := $(foreach crtapp,$(APPS),$(appdir)/$(crtapp)/.appdel)
CRTSVCS := $(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),if app["env"].has_key?("$(stackpfx)svcname"); print "$(appdir)/"+app["name"]+"/.svc " end))
DELSVCS := $(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),if app["env"].has_key?("$(stackpfx)svcname"); print app["env"]["$(stackpfx)svcname"]+"/.svcdel " end))


all: appstack

clean:
		rm -rf $(cfbindir) $(srcdir) $(appdir)

cfclean: deleteapps deletesvcs

deleteapps: cfset $(DELAPPS)

deletesvcs: cfset $(DELSVCS)

appstack: $(CRTSVCS) $(CRTAPPS)

cfset: $(cfcmd)
		$(shmute)$(cfcall) login -u $(cfuser) -p "$(cfpass)" -a $(cfapi) -o $(cforg) -s $(cfspace) --skip-ssl-validation $(nulout)
		$(info [$(stackpfx)] cf authenticated user: $(cfuser), API: $(cfapi), Org: $(cforg), Space: $(cfspace))

%/.dir:
		$(info $(call i_dircrte,$(@D)))
		$(shmute)mkdir -p $(@D)
		$(shmute)touch $@

$(appdir)/%/.appdel:
		$(info $(call i_appdele,$(subst $(appdir)/,,$(@D))))
		$(shmute)if [ "`$(cfcall) apps | grep "^$(subst $(appdir)/,,$(@D))\ "`" ]; then $(cfcall) delete -f $(subst $(appdir)/,,$(@D)) $(nulout); fi

%/.svcdel:
		$(info $(call i_svcdele,$(@D)))
		$(shmute)$(cfcall) delete-service -f $(@D) $(nulout)

$(appdir)/%/.svc: $(appdir)/%/.app
		$(eval svcname:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)svcname"])))
		$(eval locsvcparams:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)svcparams"])))
		$(eval remoteparams:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/^$(stackpfx)svcparams:\ /{print $$2}'))
		$(eval remoteurl:=$(shell $(cfcall) app $(subst $(appdir)/,,$(@D)) |awk '/^urls:\ /{gsub(",","");print $$2}'))
		$(eval boundapps:=$(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),if app["services"]; if app["services"].include?("$(svcname)"); print app["name"]+" " end end )))
		$(shmute)if [ "$(locsvcparams)" ]; then svcparams='$(locsvcparams)'; else svcparams='{"host":"http://$(remoteurl)/"}'; fi; \
                if [ "`$(call s_unquote) $$svcparams`" != "`$(call s_unquote) '$(remoteparams)'`" ]; then \
                  $(cfcall) set-env $(subst $(appdir)/,,$(@D)) $(stackpfx)svcparams \'$${svcparams}\' $(nulout); \
                fi; \
                if [ "`$(cfcall) services | grep '^$(svcname)\ '`" ]; then \
                  echo "$(call i_svcupdt,$(svcname))"; \
                  $(cfcall) uups $(svcname) -p $${svcparams} $(nulout); \
                  for boundapp in $(boundapps); do \
                    if [ "`$(cfcall) apps | grep "^$${boundapp}\ "`" ]; then \
                      echo "$(call i_apprstg) $${boundapp}"; \
                      $(cfcall) unbind-service $${boundapp} $(svcname) $(nulout); \
                      $(cfcall) bind-service $${boundapp} $(svcname) $(nulout); \
                      $(cfcall) restage $${boundapp} $(nulout); \
                    fi \
                  done \
                else \
                  echo "$(call i_svccrte,$(svcname))"; \
                  $(cfcall) cups $(svcname) -p $${svcparams} $(nulout); \
                fi; \

$(appdir)/%/.app: $(appdir)/%/$(appmfst) | $(appdir)/%/.changed
		$(shmute)if [ -f $| ]; then \
		  echo "$(call i_apppush,$(subst $(appdir)/,,$(@D)))"; \
                  $(cfcall) push -p $(@D) -f $(@D)/$(appmfst) $(nulout); \
                else \
                  echo "$(call i_appnchg,$(subst $(appdir)/,,$(@D)))"; \
                fi

$(appdir)/%/.changed: $(appdir)/%/.domain | cfset
		$(eval localver:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)version"])))
		$(eval remotever:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/^$(stackpfx)version:\ /{print $$2}'))
		$(eval localmem:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["memory"]) |sed 's/[A-Za-z]//g'))
		$(eval remotemem:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/"mem":/{print $$2}'))
		$(shmute)if [ '$(localver)' != '$(remotever)' ]; then touch $@; fi
		$(shmute)if [ '$(localmem)' != '$(remotemem)' ]; then touch $@; fi
		$(shmute)[ `cat $(@D)/.localdomain` = "nil" ] || $(cfcall) app $(subst $(appdir)/,,$(@D)) | grep -q `cat $(@D)/.localdomain` || touch $@


$(appdir)/%/.localdomain: $(appdir)/%/$(appmfst)
		$(shmute)$(call r_appgetattr,$<,$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["domain"]) >$@

$(appdir)/%/.domain: $(appdir)/%/.localdomain | cfset
		$(shmute)$(cfcall) domains | awk '{if (NR>2) print $$1}' >$@
		$(shmute)[ `cat $<` = "nil" ] || grep -q `cat $<` $@ || $(cfcall) create-domain $(cforg) `cat $<`

$(appdir)/%/$(appmfst): $(appdir)/%/manifest.yml $(stackyml)
		$(info [$(stackpfx)] creating manifest for $(subst $(appdir)/,,$(@D)))
		$(shmute)$(ruby) $(call r_mergeymls,$<,$(stackyml),$(subst $(appdir)/,,$(@D))) >$@

$(appdir)/%/manifest.yml: $(appdir)/%/.dir | $(srcdir)/%.zip
		$(info $(call i_appunzp,$(subst $(appdir)/,,$(@D))))
		$(shmute)$(unzip) -d $(@D) $|

$(srcdir)/%.zip: $(srcdir)/.dir
		$(info $(call i_appdnld,$(basename $(@F))))
		$(shmute)$(curl) -o $@ `$(call r_appgetattr,$(stackyml),$(yml_appseq),app["name"]=="$(basename $(@F))",["env"]["$(stackpfx)srcurl"])`

# the recipes below are for setting up Cloud Foundry CLI binary
$(cfarchive): | $(cfbindir)/.dir
		$(info $(call i_cfdwnld))
		$(shmute)$(curl) -o $@ $(cfarcurl)

$(cfbinary): $(cfarchive)
		$(info $(call i_cfunzip))
		$(shmute)tar -C $(cfbindir) -xzmf $<
		$(shmute)mv $(cfbindir)/cf $@

$(cfcmd): $(cfbinary)
		$(shmute)ln -fs $(<F) $@

