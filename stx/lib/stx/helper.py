# Copyright (c) 2021 Wind River Systems, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os
import sys


def help_config():
    return 'Try \'%s config --help\' for more information.\n' % os.path.basename(sys.argv[0])


def help_control():
    return 'Try \'%s control --help\' for more information.\n' % os.path.basename(sys.argv[0])


def help_build():
    return 'Try \'%s build --help\' for more information.\n' % os.path.basename(sys.argv[0])


def help_blurb():
    return 'Try \'%s --help\' for more information.\n' % os.path.basename(sys.argv[0])
