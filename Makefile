include *.mk

# defaults for external programs and others
comma:=,
SHELL = /bin/bash
ruby = ruby -ryaml -rjson -e
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
ifeq (,$(shell which ruby))
  $(error "No ruby in $(PATH), consider doing apt-get install ruby")
endif
ifneq (,$(shell ruby -e 'begin require "yaml"; rescue LoadError => e; puts e; end'))
  $(error "No ruby YAML module available, consider installing one")
endif
ifneq (,$(shell ruby -e 'begin require "json"; rescue LoadError => e; puts e; end'))
  $(error "No ruby JSON module available, consider installing one")
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
r_rmerge = class Hash; def rmerge(h); self.merge!(h) {|key,_old,_new| if _old.class == Hash then _old.rmerge(_new) else _new end } end end;
r_ymllistdo = $(ruby) 'YAML.load(File.open("$(1)"))["$(2)"].each { |app| $(3) }'
r_appgetattr = $(ruby) 'puts YAML.load(File.open("$(1)"))["$(2)"].uniq.find { |app| $(3) }$(4)'
r_appgetdeps = $(ruby) 'myaml=YAML.load(File.open("$(1)"))["$(2)"]; \
               myaml.each { |app| if app["name"]=="$(3)" and app.has_key?("services"); \
               app["services"].each { |svc| print "$(appdir)/"+myaml.uniq.find { |svcapp| svcapp["env"]["$(stackpfx)svcname"]==svc }["name"]+"/.svc " }; \
               end }'
r_mergeymls = $(ruby) '$(r_rmerge) puts YAML.dump(Hash["$(3)",[YAML.load(File.open("$(1)"))["$(3)"][0].rmerge(YAML.load(File.open("$(2)"))["$(3)"][0])]])'
r_attrcryml = $(ruby) 'puts YAML.dump(Hash["$(1)",[Hash[$(2)]]])'
r_ymlappxtc = $(ruby) 'puts YAML.dump(Hash["$(2)",[YAML.load(File.open("$(1)"))["$(2)"].find { |app| $(3) }]])'
r_json2yaml = $(ruby) 'puts YAML.dump(JSON.parse(File.open("$(1)").read))'
r_cfdscover = $(ruby) 'puts YAML.dump(Hash["applications",YAML::load(STDIN.read)["apps"].map{|app| {"name"=>app["name"],"instances"=>app["instances"],"memory"=>app["memory"].to_s+"M","services"=>app["service_names"],"domains"=>app["routes"].map{|route| route["domain"]["name"]},"env"=>app["environment_json"]}}])'
              
s_unquote = sed -e 's/"\|'\''//g' <<<
i_dircrte = [$(stackpfx)] ----->[dir] create: $(1) 
i_cfdwnld = [$(stackpfx)] ««««««[cli] download
i_cfunzip = [$(stackpfx)] ..ooOO[cli] binary uncompress
i_cflogin = [$(stackpfx)] -{ok}-[cli] authenticated: $(1)
i_domcrte = [$(stackpfx)] -»-»-»[dom] create: $(1)
i_apppush = [$(stackpfx)] -»-»-»[app] push: $(1)
i_appcrmf = [$(stackpfx)] ->->->[app] create manifest: $(1)
i_apprstg = [$(stackpfx)] --»«--[app] restage: $(1)
i_appnchg = [$(stackpfx)] ======[app] up to date: $(1)
i_appdnld = [$(stackpfx)] ««««««[app] download artifact: $(1)
i_appunzp = [$(stackpfx)] ..ooOO[app] uncompress artifact: $(1)
i_appdele = [$(stackpfx)] xxxxxx[app] delete: $(1)
i_svccrte = [$(stackpfx)] -»-»-»[svc] create user-provided-service: $(1)
i_svcupdt = [$(stackpfx)] --»«--[svc] update user-provided-service: $(1)
i_svcdele = [$(stackpfx)] xxxxxx[svc] delete: $(1)

.PRECIOUS: %/.dir $(srcdir)/%.zip $(appdir)/%/manifest.yml $(appdir)/%/$(appmfst)

APPS := $(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),print app["name"]+" " ))
DPLAPPS := $(foreach dplapp,$(APPS),$(appdir)/$(dplapp)/.app)
DELAPPS := $(foreach dplapp,$(APPS),$(appdir)/$(dplapp)/.appdel)
DELSVCS := $(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),if app["env"].has_key?("$(stackpfx)svcname"); print app["env"]["$(stackpfx)svcname"]+"/.svcdel " end))

all: deploy

MAKEFILE_TARGETS_WITHOUT_INCLUDE := wipeall clean cfclean deleteapps deletesvcs cfset discover
ifeq ($(filter $(MAKECMDGOALS),$(MAKEFILE_TARGETS_WITHOUT_INCLUDE)),)
  -include $(DPLAPPS:$(appdir)/%/.app=$(appdir)/%/.appdeps)
endif

wipeall: cfclean clean

clean:
		rm -rf $(cfbindir) $(srcdir) $(appdir)

cfclean: deleteapps deletesvcs

deleteapps: cfset $(DELAPPS)

deletesvcs: cfset $(DELSVCS)

deploy: $(DPLAPPS)
		$(shmute)rm -f $(appdir)/*/.svc  $(appdir)/*/.app

discover: | cfset
		$(eval spaceid:=$(shell $(cfcall) space --guid $(cfspace)))
		$(shmute)$(cfcall) curl /v2/spaces/$(spaceid)/summary |$(call r_cfdscover) >$@.yml

cfset: $(cfcmd)
		$(shmute)if ! $(cfcall) target -o $(cforg) -s $(cfspace) $(nulout); then \
                  $(cfcall) login -u $(cfuser) -p "$(cfpass)" -a $(cfapi) -o $(cforg) -s $(cfspace) --skip-ssl-validation $(nulout); \
                  echo "$(call i_cflogin,User:$(cfuser) API:$(cfapi) Org:$(cforg) Space:$(cfspace))"; \
                fi

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

$(appdir)/%/.svc: $(appdir)/%/.app | $(appdir)/%/.svcchanged
		$(eval svcname:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)svcname"])))
		$(eval svcparams:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/^$(stackpfx)svcparams:\ /{print $$2}'))
		$(eval boundapps:=$(shell $(call r_ymllistdo,$(stackyml),$(yml_appseq),if app["services"]; if app["services"].include?("$(svcname)"); print app["name"]+" " end end )))
		$(shmute)if [ "`$(cfcall) services | grep '^$(svcname)\ '`" ]; then \
                  if [ -f $| ]; then \
                    echo "$(call i_svcupdt,$(svcname))"; \
                    $(cfcall) uups $(svcname) -p '$(svcparams)' $(nulout); \
                    for boundapp in $(boundapps); do \
                      if [ "`$(cfcall) apps | grep "^$${boundapp}\ "`" ]; then \
                        echo "$(call i_apprstg) $${boundapp}"; \
                        $(cfcall) unbind-service $${boundapp} $(svcname) $(nulout); \
                        $(cfcall) bind-service $${boundapp} $(svcname) $(nulout); \
                        $(cfcall) restage $${boundapp} $(nulout); \
                      fi \
                    done; \
                  fi \
                else \
                    echo "$(call i_svccrte,$(svcname))"; \
                    $(cfcall) cups $(svcname) -p '$(svcparams)' $(nulout); \
                fi
		$(shmute)rm -f $|
		$(shmute)touch $@

$(appdir)/%/.svcchanged: | cfset
		$(eval locsvcparams:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)svcparams"])))
		$(eval remsvcparams:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/^$(stackpfx)svcparams:\ /{print $$2}'))
		$(eval remoteurl:=$(shell $(cfcall) app $(subst $(appdir)/,,$(@D)) |awk '/^urls:\ /{gsub(",","");print $$2}'))
		$(shmute)if [ "$(locsvcparams)" != "nil" ]; then svcparams='$(locsvcparams)'; else svcparams='{"host":"http://$(remoteurl)/"}'; fi; \
                  if [ "`$(call s_unquote) $$svcparams`" != "`$(call s_unquote) '$(remsvcparams)'`" ]; then \
                    $(cfcall) set-env $(subst $(appdir)/,,$(@D)) $(stackpfx)svcparams $${svcparams} $(nulout); \
                    touch $@; \
                  fi

$(appdir)/%/.app:
		$(shmute)if [ -f $| ]; then echo "$(call i_apppush,$(subst $(appdir)/,,$(@D)))"; fi
		$(shmute)if [ -f $| ]; then $(cfcall) push -p $(@D) -f $(@D)/$(appmfst) $(nulout); fi
		$(shmute)rm -f $|
		$(shmute)touch $@

$(appdir)/%/.appdeps: $(appdir)/%/$(appmfst)
		$(eval appdeps:=$(shell $(call r_appgetdeps,$(stackyml),$(yml_appseq),$(subst $(appdir)/,,$(@D)))))
		$(shmute)echo "$(@D)/.app $@: $(appdeps) $< | $(@D)/.appchanged" >$@

$(appdir)/%/.appchanged: $(appdir)/%/.domain | cfset
		$(eval localver:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["env"]["$(stackpfx)version"])))
		$(eval remotever:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/^$(stackpfx)version:\ /{print $$2}'))
		$(eval localmem:=$(shell $(call r_appgetattr,$(@D)/$(appmfst),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["memory"]) |sed 's/[A-Za-z]//g'))
		$(eval remotemem:=$(shell $(cfcall) env $(subst $(appdir)/,,$(@D)) |awk '/"mem":/{print $$2}'))
		$(eval localdom:=$(shell cat $(@D)/.localdomain))
		$(shmute)if [ '$(localver)' != '$(remotever)' ]; then touch $@; fi
		$(shmute)if [ '$(localmem)' != '$(remotemem)' ]; then touch $@; fi
		$(shmute)if [ "$(localdom)" != "nil" -a $$($(cfcall) app $(subst $(appdir)/,,$(@D)) | grep -c $(localdom)) -eq 0 ]; then touch $@; fi
		$(shmute)rm -f $(@D)/.domain $(@D)/.localdomain

$(appdir)/%/.localdomain: $(appdir)/%/$(appmfst)
		$(shmute)$(call r_appgetattr,$<,$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))",["domain"]) >$@

$(appdir)/%/.domain: $(appdir)/%/.localdomain | cfset
		$(eval localdom:=$(shell cat $<))
		$(shmute)$(cfcall) domains | awk '{if (NR>2) print $$1}' >$@
		$(shmute)if [ "$(localdom)" != "nil" -a $$(grep -c $(localdom) $@) -eq 0 ]; then \
                  echo "$(call i_domcrte,$(localdom))"; $(cfcall) create-shared-domain $(localdom) $(nulout); \
                fi

$(appdir)/%/$(appmfst): $(appdir)/%/manifest.yml $(stackyml)
		$(info $(call i_appcrmf,$(subst $(appdir)/,,$(@D))))
		$(shmute)$(call r_ymlappxtc,$(stackyml),$(yml_appseq),app["name"]=="$(subst $(appdir)/,,$(@D))") >$@.tmp1; mv $@.tmp1 $@
		$(shmute)$(call r_mergeymls,$<,$@,$(yml_appseq)) >$@.tmp1; mv $@.tmp1 $@

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

