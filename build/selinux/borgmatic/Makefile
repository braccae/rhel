POLICY_NAME := borgmatic
POLICY_MODULE_NAME := $(POLICY_NAME)
POLICY_VERSION := 1.0.0

# Source files
TE_FILES := $(wildcard $(POLICY_NAME).te)
IF_FILES := $(wildcard $(POLICY_NAME).if)
FC_FILES := $(wildcard $(POLICY_NAME).fc)

# Target files
PP_FILE := $(POLICY_MODULE_NAME).pp
MOD_FILE := $(POLICY_MODULE_NAME).mod

# Build rules
.PHONY: all clean install uninstall

all: $(PP_FILE)

$(PP_FILE): $(MOD_FILE)
	@echo "Compiling SELinux policy module..."
	semodule_package -o $@ -m $<

$(MOD_FILE): $(TE_FILES) $(IF_FILES)
	@echo "Building policy module..."
	checkmodule -M -m $(TE_FILES) -o $@

clean:
	@echo "Cleaning up..."
	rm -f *.mod *.pp *.te.bak

install: $(PP_FILE)
	@echo "Installing SELinux policy module..."
	semodule -i $<

uninstall:
	@echo "Uninstalling SELinux policy module..."
	semodule -r $(POLICY_NAME)

validate: $(TE_FILES) $(IF_FILES) $(FC_FILES)
	@echo "Validating policy files..."
	checkmodule -C -m $(TE_FILES)
