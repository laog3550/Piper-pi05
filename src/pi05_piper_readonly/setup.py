from glob import glob
from setuptools import find_packages, setup


package_name = 'pi05_piper_readonly'


setup(
    name=package_name,
    version='0.1.0',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages',
         ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/launch', glob('launch/*.launch.py')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='Pi05 Maintainer',
    maintainer_email='maintainer@example.com',
    description=(
        'Receive-only four-arm Piper state and diagnostics for Pi05.'
    ),
    license='Apache-2.0',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'readonly_state_node = '
            'pi05_piper_readonly.readonly_state_node:main',
        ],
    },
)
