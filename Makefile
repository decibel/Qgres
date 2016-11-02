include pgxntool/base.mk

testdeps: pg_acl

-- TODO: Remove this after merging pgxntool 0.2.1+
testdeps: $(TEST_SQL_FILES) $(TEST_SOURCE_FILES)

TEST_HELPER_FILES		= $(wildcard $(TESTDIR)/helpers/*.sql)
testdeps: $(TEST_HELPER_FILES)

# Arguably should be a dependency of install too, since you need citext to use the extension
testdeps: citext

.PHONY: citext
citext: $(DESTDIR)$(datadir)/extension/citext.control

# It would be nice if we could just make this build...
$(DESTDIR)$(datadir)/extension/citext.control:
	@echo ERROR: extension citext is not installed 1>&2
	@echo citext is required by Qgres. Please install it. 1>&2
	@exit 1

.PHONY: pg_acl
pg_acl: $(DESTDIR)$(datadir)/extension/pg_acl.control

$(DESTDIR)$(datadir)/extension/pg_acl.control:
	pgxn install --unstable pg_acl
