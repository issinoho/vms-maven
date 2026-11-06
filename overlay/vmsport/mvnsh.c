/* mvnsh.c - the "/bin/sh" Maven's plugins run on OpenVMS.

   Plugins that start a program (surefire and failsafe fork their test JVM)
   go through plexus-utils' BourneShell, which runs

       /bin/sh -c "cd '<dir>' && '<program>' '<arg>' ..."

   OpenVMS has no /bin/sh.  VSI's JVM maps the program it is asked to start
   through the logical names JAVA$EXEC_MAPPING_01, _02, ... ("/bin/sh=<image>"),
   and MVN.EXE adds one that points here.  This image understands exactly
   that kind of script: commands joined by &&, each a list of words in
   single quotes, double quotes or bare, where a command is "cd <dir>",
   "exec <program> ...", or "<program> ...".  Anything else (pipes,
   redirection, variables, ;) is refused with exit code 2, so a plugin that
   needs a real shell fails with a clear message rather than doing the wrong
   thing.

   Programs start with vfork/execv, as in MVN.EXE, so their standard input
   and output are this image's (the pipes the JVM gave it).  The exit status
   is that of the last command run; 127 if it could not be started.

   Part of vms-maven (github.com/issinoho/vms-maven); Apache License 2.0.  */

#define _POSIX_EXIT 1

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wait.h>

#define MAXWORDS 4096

static const char *prog = "mvnsh";
static int trace;

static void
fail (int code, const char *msg, const char *what)
{
  fprintf (stderr, "%s: %s%s%s\n", prog, msg, what ? ": " : "", what ? what : "");
  exit (code);
}

/* One token: a word, or the operator "&&" (op set).  */
struct token { char *text; int op; };

static struct token toks[MAXWORDS];
static int ntoks;

static void
tokenize (const char *s)
{
  size_t cap = strlen (s) + 1;
  while (*s != '\0')
    {
      char *w, *o;
      while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r')
        s++;
      if (*s == '\0')
        break;
      if (ntoks >= MAXWORDS)
        fail (2, "command too long", NULL);
      if (s[0] == '&' && s[1] == '&')
        {
          toks[ntoks].text = "&&";
          toks[ntoks++].op = 1;
          s += 2;
          continue;
        }
      w = o = malloc (cap);
      if (w == NULL)
        fail (2, "out of memory", NULL);
      while (*s != '\0' && *s != ' ' && *s != '\t' && *s != '\n' && *s != '\r')
        {
          if (*s == '\'')
            {
              const char *e = strchr (s + 1, '\'');
              if (e == NULL)
                fail (2, "unmatched ' in", s);
              memcpy (o, s + 1, e - s - 1);
              o += e - s - 1;
              s = e + 1;
            }
          else if (*s == '"')
            {
              s++;
              while (*s != '"')
                {
                  if (*s == '\0')
                    fail (2, "unmatched \" in the command", NULL);
                  if (*s == '$' || *s == '`')
                    fail (2, "variables and command substitution are not supported", s);
                  if (*s == '\\' && strchr ("\"\\$`", s[1]) != NULL)
                    s++;
                  *o++ = *s++;
                }
              s++;
            }
          else if (*s == '\\' && s[1] != '\0')
            {
              *o++ = s[1];
              s += 2;
            }
          else if (strchr ("|;&<>()$`*?[]{}~#", *s) != NULL)
            fail (2, "only \"cd DIR && PROGRAM ARGS\" is supported, not", s);
          else
            *o++ = *s++;
        }
      *o = '\0';
      toks[ntoks].text = w;
      toks[ntoks++].op = 0;
    }
}

/* Start ARGV[0] with ARGV, wait, return its exit code.  */
static int
run (char **argv)
{
  const char *image = argv[0];
  pid_t pid;
  int st = 0, i;

  /* A bare name may be a foreign-command symbol ("java" -> $...JAVA.EXE).  */
  if (strchr (image, '/') == NULL && strchr (image, ':') == NULL
      && strchr (image, '[') == NULL)
    {
      const char *sym = getenv (image);
      if (sym != NULL && *sym == '$')
        image = sym + 1;
    }
  if (trace)
    {
      fprintf (stderr, "%s: run %s", prog, image);
      for (i = 1; argv[i] != NULL; i++)
        fprintf (stderr, " [%s]", argv[i]);
      fprintf (stderr, "\n");
    }
  fflush (stderr);
  pid = vfork ();
  if (pid == 0)
    {
      execv (image, argv);
      _exit (127);
    }
  if (pid < 0)
    fail (127, "cannot start (vfork)", strerror (errno));
  if (waitpid (pid, &st, 0) < 0)
    fail (127, "waiting failed", strerror (errno));
  if (!WIFEXITED (st))
    return 1;
  if (WEXITSTATUS (st) == 127)
    fprintf (stderr, "%s: cannot run %s\n", prog, image);
  return WEXITSTATUS (st);
}

int
main (int argc, char **argv)
{
  int i = 0, rc = 0;

  trace = getenv ("MAVEN_VMS_TRACE") != NULL;
  if (argc != 3 || strcmp (argv[1], "-c") != 0)
    fail (2, "usage: sh -c \"cd DIR && PROGRAM ARGS\" (the only form supported)", NULL);
  if (trace)
    fprintf (stderr, "%s: -c [%s]\n", prog, argv[2]);
  tokenize (argv[2]);

  while (i < ntoks)
    {
      char *words[MAXWORDS + 1];
      int n = 0;
      while (i < ntoks && !toks[i].op)
        words[n++] = toks[i++].text;
      words[n] = NULL;
      if (i < ntoks)                    /* skip the && */
        {
          i++;
          if (i >= ntoks || n == 0)
            fail (2, "&& without a command", NULL);
        }
      if (n == 0)
        continue;
      if (strcmp (words[0], "cd") == 0)
        {
          const char *dir = n > 1 ? words[1] : getenv ("HOME");
          if (dir == NULL || chdir (dir) != 0)
            {
              fprintf (stderr, "%s: cd %s: %s\n", prog, dir ? dir : "", strerror (errno));
              rc = 1;
            }
          else
            rc = 0;
        }
      else if (strcmp (words[0], "exec") == 0)
        rc = n > 1 ? run (words + 1) : 0;
      else
        rc = run (words);
      if (rc != 0)
        break;
    }
  exit (rc);
}
