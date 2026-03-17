#ifndef ZOITECHAT_PREFERENCES_PERSISTENCE_H
#define ZOITECHAT_PREFERENCES_PERSISTENCE_H

#include <glib.h>

typedef struct
{
	gboolean success;
	gboolean retry_possible;
	gboolean partial_failure;
	gboolean config_failed;
	gboolean theme_failed;
	const char *failed_file;
} PreferencesPersistenceResult;

PreferencesPersistenceResult preferences_persistence_save_all (void);

#endif
