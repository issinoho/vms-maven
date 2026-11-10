/* mvn.c - the Maven launcher for OpenVMS: what bin/mvn does, as an image.

   MVN has to be an image, not a DCL procedure: DCL upper-cases the parameters
   of a procedure (P1-P8, at most eight of them), and Maven's goals, options and
   properties are case-sensitive.  An image run as a foreign command gets its
   arguments as typed when the process has SET PROCESS/PARSE_STYLE=EXTENDED
   (vms_crtl_init.c turns on DECC$ARGV_PARSE_STYLE).

   Like bin/mvn, it
     - finds the Maven home (the directory above the one holding MVN.EXE,
       or MAVEN_HOME),
     - finds Java (JAVA_HOME, or the JAVA symbol OPENJDK$SETUP.COM defines),
     - finds the project base directory: the nearest directory at or above
       the current one (or the -f/--file argument) that has a .mvn
       subdirectory, or MAVEN_BASEDIR,
     - gives Java small-footprint defaults (DEFAULT_JVM_OPTS), then the JVM
       options from <basedir>/.mvn/jvm.config and MAVEN_OPTS, and
       extra Maven arguments from MAVEN_ARGS,
   and runs Java on the classworlds launcher.  Java is started with vfork and
   execv, so the arguments reach it without passing through DCL again.  The
   exit status is Java's.

   Plugins that start programs (surefire's forked test JVM) run them through
   /bin/sh -c "cd DIR && PROGRAM ARGS".  VSI's JVM maps a program it starts
   through the logical names or variables JAVA$EXEC_MAPPING_01, _02, ...
   ("/bin/sh=<image>"); the launcher adds one for /bin/sh that points at
   MVNSH.EXE next to it (mvnsh.c), unless one already maps /bin/sh.

   It also sets VSI Java's JAVA$DELETE_ALL_VERSIONS, JAVA$RENAME_ALL_VERSIONS
   and JAVA$CREATE_DIR_WITH_OWNER_DELETE (unless defined), and makes the
   resolver lock files across processes (file-lock), since two builds
   sharing a local repository collide on OpenVMS's file locks otherwise.
   A local repository that does not exist yet is created with a version
   limit of 1, so files Maven rewrites there do not pile up versions.

   Environment variables are read with getenv(), so each may be a DCL symbol
   or a logical name.  MAVEN_VMS_TRACE (any value) prints the Java command.

   Part of vms-maven (github.com/issinoho/vms-maven); Apache License 2.0.  */

#define _POSIX_EXIT 1           /* exit(n) gives the status Java's exit(n) does */

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wait.h>
#include <unixlib.h>

#include <descrip.h>
#include <jpidef.h>
#include <lib$routines.h>
#include <ssdef.h>

#define MAXARGS 1024

#define DEFAULT_JVM_OPTS \
  "-Xms16m -Xmx128m -XX:+UseSerialGC -XX:ReservedCodeCacheSize=32m " \
  "-Daether.syncContext.named.factory=file-lock " \
  "-Daether.syncContext.named.nameMapper=file-gav"

static const char *prog = "mvn";
static char *jargv[MAXARGS];
static int jargc;

static void
die (const char *msg, const char *what)
{
  fprintf (stderr, "%s: %s%s%s\n", prog, msg, what ? ": " : "", what ? what : "");
  exit (1);
}

static char *
xstrdup (const char *s)
{
  char *d = strdup (s);
  if (d == NULL)
    die ("out of memory", NULL);
  return d;
}

static char *
concat (const char *a, const char *b)
{
  char *d = malloc (strlen (a) + strlen (b) + 1);
  if (d == NULL)
    die ("out of memory", NULL);
  strcpy (d, a);
  strcat (d, b);
  return d;
}

static void
add (const char *arg)
{
  if (jargc >= MAXARGS - 1)
    die ("too many arguments", NULL);
  jargv[jargc++] = (char *) arg;
}

/* Add each whitespace-separated word of S, as bin/mvn's unquoted
   $MAVEN_OPTS and jvm.config do.  */
static void
add_words (const char *s)
{
  char *copy, *w;
  if (s == NULL)
    return;
  copy = xstrdup (s);
  for (w = strtok (copy, " \t\r\n"); w != NULL; w = strtok (NULL, " \t\r\n"))
    add (w);
}

/* A file specification in VMS form (DEV:[DIR]NAME) becomes a Unix path;
   anything else is returned as it is.  */
static char *
unix_path (const char *spec)
{
  char *u;
  if (strchr (spec, ':') == NULL && strchr (spec, '[') == NULL
      && strchr (spec, '<') == NULL)
    return xstrdup (spec);
  u = decc$translate_vms (spec);
  if (u == NULL || u == (char *) -1)
    die ("cannot translate to a Unix path", spec);
  return xstrdup (u);
}

static void
strip_trailing_slash (char *p)
{
  size_t n = strlen (p);
  while (n > 1 && p[n - 1] == '/')
    p[--n] = '\0';
}

/* "/a/b/c" -> "/a/b"; "/a" -> "/".  Returns 0 at the root.  */
static int
parent (char *p)
{
  char *s;
  strip_trailing_slash (p);
  if (strcmp (p, "/") == 0)
    return 0;
  s = strrchr (p, '/');
  if (s == NULL)
    return 0;
  if (s == p)
    s[1] = '\0';
  else
    *s = '\0';
  return 1;
}

static int
is_dir (const char *p)
{
  struct stat st;
  return stat (p, &st) == 0 && S_ISDIR (st.st_mode);
}

static int
is_file (const char *p)
{
  struct stat st;
  return stat (p, &st) == 0 && !S_ISDIR (st.st_mode);
}

static char *
join (const char *dir, const char *name)
{
  size_t n = strlen (dir);
  char *d = malloc (n + strlen (name) + 2);
  if (d == NULL)
    die ("out of memory", NULL);
  strcpy (d, dir);
  if (n == 0 || dir[n - 1] != '/')
    strcat (d, "/");
  strcat (d, name);
  return d;
}

static char *
cwd (void)
{
  char buf[4096];
  if (getcwd (buf, sizeof buf, 0) == NULL)      /* 0: Unix form */
    die ("cannot get the current directory", strerror (errno));
  return xstrdup (buf);
}

/* Maven home: MAVEN_HOME, else the parent of the directory holding this image.  */
static char *
maven_home (void)
{
  const char *env = getenv ("MAVEN_HOME");
  char image[256];
  unsigned short len = 0;
  int code = JPI$_IMAGNAME, status;
  char *u, *semi;
  struct dsc$descriptor_s d;

  if (env != NULL && *env != '\0')
    {
      u = unix_path (env);
      strip_trailing_slash (u);
      return u;
    }
  d.dsc$w_length = sizeof image - 1;
  d.dsc$b_dtype = DSC$K_DTYPE_T;
  d.dsc$b_class = DSC$K_CLASS_S;
  d.dsc$a_pointer = image;
  status = lib$getjpi (&code, 0, 0, 0, &d, &len);
  if (!(status & 1))
    die ("cannot find this image's name (LIB$GETJPI)", NULL);
  image[len] = '\0';
  semi = strchr (image, ';');
  if (semi != NULL)
    *semi = '\0';
  u = unix_path (image);
  /* .../bin/MVN.EXE -> .../bin -> ... */
  if (!parent (u) || !parent (u))
    die ("cannot find the Maven home from", image);
  return u;
}

/* Java: $JAVA_HOME/bin/java, else the image the JAVA symbol runs.  */
static char *
java_image (void)
{
  const char *env = getenv ("JAVA_HOME");
  const char *sym;
  if (env != NULL && *env != '\0')
    {
      char *home = unix_path (env), *bin = join (home, "bin/java");
      if (!is_file (concat (bin, ".exe")) && !is_file (bin))
        die ("JAVA_HOME does not contain bin/java", env);
      return bin;
    }
  sym = getenv ("JAVA");
  if (sym != NULL && *sym == '$')
    return xstrdup (sym + 1);
  die ("Java not found: set JAVA_HOME, or run @SYS$STARTUP:OPENJDK$SETUP.COM", NULL);
  return NULL;
}

/* The directory bin/mvn starts its .mvn search from: the -f/--file
   argument (its directory, if it names a file), else the current one.  */
static char *
start_dir (int argc, char **argv)
{
  int i;
  char *here = cwd ();
  for (i = 1; i + 1 < argc; i++)
    if (strcmp (argv[i], "-f") == 0 || strcmp (argv[i], "--file") == 0)
      {
        char *f = unix_path (argv[i + 1]);
        if (f[0] != '/')
          f = join (here, f);
        if (is_dir (f))
          return f;
        if (parent (f) && is_dir (f))
          return f;
        die ("POM file or directory not found", argv[i + 1]);
      }
  return here;
}

static char *
find_basedir (int argc, char **argv)
{
  const char *env = getenv ("MAVEN_BASEDIR");
  char *start, *dir;
  if (env != NULL && *env != '\0')
    return unix_path (env);
  start = start_dir (argc, argv);
  strip_trailing_slash (start);
  dir = xstrdup (start);
  do
    {
      if (strcmp (dir, "/") != 0 && is_dir (join (dir, ".mvn")))
        return dir;
    }
  while (parent (dir));
  return start;
}

/* The concatenated words of FILE, or NULL if it does not exist.  */
static char *
read_words (const char *file)
{
  FILE *f = fopen (file, "r");
  char line[4096], *all = xstrdup ("");
  if (f == NULL)
    return NULL;
  while (fgets (line, sizeof line, f) != NULL)
    {
      all = concat (all, line);
      all = concat (all, " ");
    }
  fclose (f);
  return all;
}

static char *
classworlds_jar (const char *home)
{
  char *boot = join (home, "boot");
  DIR *d = opendir (boot);
  struct dirent *e;
  char *found = NULL;
  if (d == NULL)
    die ("cannot read", boot);
  while ((e = readdir (d)) != NULL)
    {
      const char *n = e->d_name;
      size_t len = strlen (n);
      if (strncasecmp (n, "plexus-classworlds-", 19) == 0 && len > 4
          && strcasecmp (n + len - 4, ".jar") == 0)
        found = join (boot, n);
    }
  closedir (d);
  if (found == NULL)
    die ("no plexus-classworlds jar in", boot);
  return found;
}

/* VSI Java's file behaviour that Maven needs (NOTES N15), unless the site
   has set these itself.  Without them a file Java rewrites gets a new
   version and delete removes only the newest, so the local repository
   collects versions and "clean" cannot delete target/.  */
static void
java_file_settings (void)
{
  static const char *names[] = {
    "JAVA$DELETE_ALL_VERSIONS",
    "JAVA$RENAME_ALL_VERSIONS",
    "JAVA$CREATE_DIR_WITH_OWNER_DELETE",
  };
  size_t i;
  for (i = 0; i < sizeof names / sizeof names[0]; i++)
    if (getenv (names[i]) == NULL)
      setenv (names[i], "TRUE", 1);
}

/* Map /bin/sh to MVNSH.EXE for Java (see the top of this file).  */
static void
map_sh (const char *home)
{
  char name[32];
  int i;
  for (i = 1; i <= 99; i++)
    {
      const char *v;
      sprintf (name, "JAVA$EXEC_MAPPING_%02d", i);
      v = getenv (name);
      if (v == NULL)
        break;
      if (strncmp (v, "/bin/sh=", 8) == 0)
        return;                         /* the site's own mapping */
    }
  if (i > 99)
    return;
  setenv (name, concat ("/bin/sh=", join (home, "bin/mvnsh.exe")), 1);
}

/* The local repository: the last maven.repo.local given to Java or Maven
   (-Dmaven.repo.local=X, or -D/--define maven.repo.local=X), else
   ~/.m2/repository.  A <localRepository> in settings.xml is not seen here.  */
static char *
local_repository (void)
{
  static const char key[] = "maven.repo.local=";
  const size_t klen = sizeof key - 1;
  const char *found = NULL, *home;
  int i;
  for (i = 1; i < jargc; i++)
    {
      const char *a = jargv[i];
      if (strncmp (a, "-D", 2) == 0 && strncmp (a + 2, key, klen) == 0)
        found = a + 2 + klen;
      else if ((strcmp (a, "-D") == 0 || strcmp (a, "--define") == 0)
               && i + 1 < jargc && strncmp (jargv[i + 1], key, klen) == 0)
        found = jargv[i + 1] + klen;
    }
  if (found != NULL && *found != '\0')
    return unix_path (found);
  home = getenv ("HOME");
  return home != NULL ? join (unix_path (home), ".m2/repository") : NULL;
}

/* Create a missing local repository with a version limit of 1 (NOTES N19).
   Java on OpenVMS writes a new version of a file each time it rewrites it,
   so maven-metadata-local.xml, checksums and reinstalled artifacts pile up;
   in a directory with limit 1, a new version replaces the old one, and the
   directories Java creates below inherit the limit.  An existing repository
   is left as it is (README.VMS says how to set the limit on one).  */
static void
make_repository (const char *repo)
{
  char *p, *s;
  int code = JPI$_UIC;
  unsigned int uic = 0;
  if (repo == NULL || is_dir (repo))
    return;
  p = xstrdup (repo);
  strip_trailing_slash (p);
  for (s = strchr (p + 1, '/'); s != NULL; s = strchr (s + 1, '/'))
    {
      *s = '\0';
      if (!is_dir (p))
        mkdir (p, 0777);
      *s = '/';
    }
  /* The DEC C mkdir's extra arguments: owner UIC, then the version limit.  */
  if (!(lib$getjpi (&code, 0, 0, &uic, 0, 0) & 1))
    uic = 0;
  if (mkdir (p, 0777, uic, 1) != 0 && getenv ("MAVEN_VMS_TRACE") != NULL)
    fprintf (stderr, "%s: cannot create %s: %s\n", prog, p, strerror (errno));
}

/* Java on OpenVMS wants far larger quotas than a default account has (HP's
   Java user guide: FILLM 4096, PGFLQUOTA 2097152), and a forked test JVM
   shares them with Maven's JVM (NOTES N12, N14).  Note low ones after a
   failure, when they may be why.  */
#define WANT_FILLM 4096
#define WANT_PGFLQUOTA 2097152

static void
note_quotas (void)
{
  int c1 = JPI$_FILLM, c2 = JPI$_PGFLQUOTA, fillm = 0, pgfl = 0;
  if (!(lib$getjpi (&c1, 0, 0, &fillm, 0, 0) & 1)
      || !(lib$getjpi (&c2, 0, 0, &pgfl, 0, 0) & 1))
    return;
  if (fillm >= WANT_FILLM && pgfl >= WANT_PGFLQUOTA)
    return;
  fprintf (stderr, "%s: note: this account's quotas are low for Java (FILLM %d, "
           "PGFLQUOTA %d; Java on OpenVMS wants FILLM %d and PGFLQUOTA %d): "
           "\"unable to create new native thread\", \"could not reserve enough "
           "space\" or a test JVM that fails to start come from that\n",
           prog, fillm, pgfl, WANT_FILLM, WANT_PGFLQUOTA);
}

/* The process's parse style: 1 if EXTENDED.  */
static int
parse_extended (void)
{
  int code = JPI$_PARSE_STYLE_PERM, value = 0;
  if (!(lib$getjpi (&code, 0, 0, &value, 0, 0) & 1))
    return 1;
  return value != 0;
}

int
main (int argc, char **argv)
{
  char *home, *java, *basedir, *jvmconfig;
  pid_t pid;
  int i, st = 0, rc;

  home = maven_home ();
  java = java_image ();
  basedir = find_basedir (argc, argv);
  map_sh (home);
  java_file_settings ();

  add ("java");
  /* Small-footprint defaults (NOTES N12): a forked test JVM shares this
     JVM's page file quota.  They come first, so jvm.config and MAVEN_OPTS
     override them (the JVM takes the last of each option).  */
  add_words (DEFAULT_JVM_OPTS);
  jvmconfig = read_words (join (basedir, ".mvn/jvm.config"));
  add_words (jvmconfig);
  add_words (getenv ("MAVEN_OPTS"));
  add_words (getenv ("MAVEN_DEBUG_OPTS"));
  add ("-classpath");
  add (classworlds_jar (home));
  add (concat ("-Dclassworlds.conf=", join (home, "bin/m2.conf")));
  add (concat ("-Dmaven.home=", home));
  add (concat ("-Dlibrary.jansi.path=", join (home, "lib/jansi-native")));
  add (concat ("-Dmaven.multiModuleProjectDirectory=", basedir));
  add ("org.codehaus.plexus.classworlds.launcher.Launcher");
  add_words (getenv ("MAVEN_ARGS"));
  for (i = 1; i < argc; i++)
    add (argv[i]);
  jargv[jargc] = NULL;
  make_repository (local_repository ());

  if (getenv ("MAVEN_VMS_TRACE") != NULL)
    {
      fprintf (stderr, "%s: %s", prog, java);
      for (i = 1; i < jargc; i++)
        fprintf (stderr, " \"%s\"", jargv[i]);
      fprintf (stderr, "\n");
    }

  fflush (stdout);
  fflush (stderr);
  pid = vfork ();
  if (pid == 0)
    {
      execv (java, jargv);
      _exit (127);
    }
  if (pid < 0)
    die ("cannot start Java (vfork)", strerror (errno));
  if (waitpid (pid, &st, 0) < 0)
    die ("waiting for Java failed", strerror (errno));
  if (WIFEXITED (st))
    rc = WEXITSTATUS (st);
  else
    rc = 1;
  if (rc == 127)
    die ("cannot run Java", java);
  if (rc != 0)
    note_quotas ();
  if (rc != 0 && !parse_extended () && argc > 1)
    fprintf (stderr, "%s: note: this process has the TRADITIONAL parse style, so "
             "arguments not in quotes reached Maven in lower case "
             "(SET PROCESS/PARSE_STYLE=EXTENDED, or quote them)\n", prog);
  /* exit(), not return: only exit() maps the code to a VMS status under
     _POSIX_EXIT, and return 1 would be SS$_NORMAL.  */
  exit (rc);
}
