pragma solidity ^0.5.0;

contract FisherYatesShuffle {

   uint[] public arr;
   uint public arraySize;

   uint public randomNumber = 997654321;

   constructor(uint _arraySize) public{
     arraySize = _arraySize;
     arr = new uint[](arraySize);
   }

function initArray() public returns( uint ){
      arr = new uint[](arraySize);
      uint i = 0;

      while (i < arraySize ) {
        arr[i] = i + 1;
        i++;
      }
      
   }

   function shuffleArray() public returns( uint ){
      uint i = arr.length;
      uint temp;
      uint r;

      while (i > 1 ) {
        i--;
        temp = arr[i];
        r = randomNumber % i;
        arr[i] = arr[r];
        arr[r] = temp;

      }
   }

}
