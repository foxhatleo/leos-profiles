#include <dirent.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <strings.h>

int copy(char *source, char* dest) {
  FILE *source_file, *dest_file;
  char ch;
  int pos;
  if ((source_file = fopen(source, "r")) == NULL) {
      return 1;
  }
  dest_file = fopen(dest, "w");
  fseek(source_file, 0L, SEEK_END);
  pos = ftell(source_file);
  fseek(source_file, 0L, SEEK_SET);
  while (pos--) {
      ch = fgetc(source_file);
      fputc(ch, dest_file);
  }
  fclose(source_file);
  fclose(dest_file);
  return 0;
}

void remove_ds_store(char *name) {
  DIR *dir;
  struct dirent *entry;

  int state = 0;
  bool ds_store_exists = false;

  if (!(dir = opendir(name))) return;

  while ((entry = readdir(dir)) != NULL) {
    if (entry->d_type == DT_DIR) {
      if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
        continue;

      char *subdir_path = (char *)malloc(2 + strlen(name) + strlen(entry->d_name));
      strcpy(subdir_path, name);
      strcat(subdir_path, entry->d_name);
      strcat(subdir_path, "/");
      remove_ds_store(subdir_path);
      free(subdir_path);

    } else if (strcasecmp(entry->d_name, ".backup.DS_Store") == 0) {
      state = 2;

    } else if (strcasecmp(entry->d_name, ".keep.DS_Store") == 0) {
      state = 1;

    } else if (strcasecmp(entry->d_name, ".DS_Store") == 0) {
      ds_store_exists = true;
    }
  }

  char *ds_path = (char *)malloc(10 + strlen(name));
  char *b;
  strcpy(ds_path, name);
  strcat(ds_path, ".DS_Store");

  if (ds_store_exists) {
    switch (state) {
      case 0:
      case 2:
        b = (remove(ds_path) == 0) ? "Success" : "Fail";
        printf("Removing %s... %s.\n", ds_path, b);
        break;
      case 1:
        printf("Found but keeping %s.\n", ds_path);
        break;
    }
  }

  if (state == 2) {
    char *bu_path = (char *)malloc(17 + strlen(name));
    strcpy(bu_path, name);
    strcat(bu_path, ".backup.DS_Store");
    b = (copy(bu_path, ds_path) == 0) ? "Success" : "Fail";
    printf("Recovering from backup: %s... %s.\n", ds_path, b);
    free(bu_path);
  }
  free(ds_path);

  closedir(dir);
}

int main() {
  remove_ds_store("/");
  return 0;
}
