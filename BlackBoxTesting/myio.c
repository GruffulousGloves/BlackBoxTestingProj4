// Project 4 C file for CSE 420
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#define BLOCK_SIZE 4096

int main(int argc, char *argv[])
{
    int fd;
    int mode;
    long file_size;
    char buffer[BLOCK_SIZE];

    // Check the number of command-line arguments
    if (argc != 4)
    {
        fprintf(stderr, "Usage: %s 1 <filename> <file_size>\n", argv[0]);
        return 1;
    }

    // Get the operation mode
    mode = atoi(argv[1]);

    // Detects invalid mode (though only file creation mode is implemented right now)
    if (mode != 1 && mode != 2)
    {
        fprintf(stderr, "Error: Invalid mode.\n");
        return 1;
    }

    // Get the requested file size in blocks
    file_size = atol(argv[3]);

    if (file_size <= 0)
    {
        fprintf(stderr, "Error: File size must be positive.\n");
        return 1;
    }

    // Initialize the entire buffer to binary zeros
    memset(buffer, 0, BLOCK_SIZE);

    // Create or overwrite the file
    fd = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0664);

    if (fd == -1)
    {
        perror("Error opening file");
        return 1;
    }

    // Write exactly file_size blocks
    for (long i = 0; i < file_size; i++)
    {
        ssize_t bytes_written;

        bytes_written = write(fd, buffer, BLOCK_SIZE);

        if (bytes_written != BLOCK_SIZE)
        {
            perror("Error writing block");
            close(fd);
            return 1;
        }
    }

    // Synchronize file contents with storage
    if (fsync(fd) == -1)
    {
        perror("Error synchronizing file");
        close(fd);
        return 1;
    }

    // Close the file
    if (close(fd) == -1)
    {
        perror("Error closing file");
        return 1;
    }

    return 0;
}