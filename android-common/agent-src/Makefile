NDK=/home/ubuntu/Android/Sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt/linux-x86_64
CC_DIR="${NDK}/bin"
CC = ${CC_DIR}/aarch64-linux-android28-clang++
CFLAGS = -fPIC -shared -static-libstdc++ -llog
INCLUDES = -I/usr/lib/jvm/java-1.8.0-openjdk-amd64/include/linux \
			-I/usr/lib/jvm/java-1.8.0-openjdk-amd64/include \
			-I${NDK}/sysroot/usr/include/android
SRC = agent.cpp
TARGET = libagent.so

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(INCLUDES) $(SRC) -o $(TARGET)

clean:
	rm -f $(TARGET) 

.PHONY: clean
